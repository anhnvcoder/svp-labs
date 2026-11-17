package counter

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

const (
	videoA = "0b7e4a52-3c1d-4f7a-9e2b-5d6c7f8a9b0c"
	videoB = "6f1c2d3e-4a5b-4c6d-8e7f-901a2b3c4d5e"
)

var now = time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)

// fakeDB keeps the table in memory and checks the dedupe put's condition the way DynamoDB does. failNext, when
// set, is returned by the next call instead of writing.
type fakeDB struct {
	items    map[string]map[string]types.AttributeValue
	failNext error
	calls    int
}

func newFakeDB() *fakeDB { return &fakeDB{items: map[string]map[string]types.AttributeValue{}} }

func (f *fakeDB) TransactWriteItems(_ context.Context, in *dynamodb.TransactWriteItemsInput,
	_ ...func(*dynamodb.Options)) (*dynamodb.TransactWriteItemsOutput, error) {
	f.calls++
	if err := f.failNext; err != nil {
		f.failNext = nil
		return nil, err
	}
	put, upd := in.TransactItems[0].Put, in.TransactItems[1].Update
	if aws.ToString(put.ConditionExpression) != "attribute_not_exists(pk)" {
		return nil, errors.New("fake: unexpected condition " + aws.ToString(put.ConditionExpression))
	}
	if aws.ToString(upd.UpdateExpression) != "ADD #views :one" || upd.ExpressionAttributeNames["#views"] != "views" {
		return nil, errors.New("fake: unexpected update " + aws.ToString(upd.UpdateExpression))
	}
	pk := put.Item["pk"].(*types.AttributeValueMemberS).Value
	if _, ok := f.items[pk]; ok {
		return nil, &types.TransactionCanceledException{CancellationReasons: []types.CancellationReason{
			{Code: aws.String("ConditionalCheckFailed")}, {Code: aws.String("None")},
		}}
	}
	f.items[pk] = put.Item
	key := upd.Key["pk"].(*types.AttributeValueMemberS).Value
	n := 0
	if v, ok := f.items[key]["views"]; ok {
		n, _ = strconv.Atoi(v.(*types.AttributeValueMemberN).Value)
	}
	f.items[key] = map[string]types.AttributeValue{
		"pk":    upd.Key["pk"],
		"views": &types.AttributeValueMemberN{Value: strconv.Itoa(n + 1)},
	}
	return &dynamodb.TransactWriteItemsOutput{}, nil
}

func (f *fakeDB) views(t *testing.T, video string) int {
	t.Helper()
	v, ok := f.items["video#"+video]["views"]
	if !ok {
		return 0
	}
	n, err := strconv.Atoi(v.(*types.AttributeValueMemberN).Value)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func newHandler(db TransactWriter, metrics io.Writer) *Handler {
	return &Handler{
		DB:        db,
		Table:     "svp-lab-sls-views",
		DedupeTTL: 5 * 24 * time.Hour,
		Now:       func() time.Time { return now },
		Metrics:   metrics,
		Log:       slog.New(slog.NewJSONHandler(io.Discard, nil)),
	}
}

func message(id, eventID, body string) events.SQSMessage {
	m := events.SQSMessage{
		MessageId:         id,
		Body:              body,
		Attributes:        map[string]string{"SentTimestamp": strconv.FormatInt(now.Add(-1500*time.Millisecond).UnixMilli(), 10)},
		MessageAttributes: map[string]events.SQSMessageAttribute{},
	}
	if eventID != "" {
		m.MessageAttributes["event_id"] = events.SQSMessageAttribute{StringValue: aws.String(eventID), DataType: "String"}
	}
	return m
}

func view(id, eventID, video string) events.SQSMessage {
	return message(id, eventID, `{"video_id":"`+video+`"}`)
}

func failures(t *testing.T, resp events.SQSEventResponse) []string {
	t.Helper()
	ids := []string{}
	for _, f := range resp.BatchItemFailures {
		ids = append(ids, f.ItemIdentifier)
	}
	return ids
}

// emfLines decodes the metric lines and returns, per metric name, the values in order.
func emfLines(t *testing.T, buf *bytes.Buffer) map[string][]float64 {
	t.Helper()
	got := map[string][]float64{}
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		if line == "" {
			continue
		}
		var doc struct {
			AWS struct {
				Timestamp         int64
				CloudWatchMetrics []struct {
					Namespace  string
					Dimensions [][]string
					Metrics    []struct{ Name, Unit string }
				}
			} `json:"_aws"`
			Function string
		}
		if err := json.Unmarshal([]byte(line), &doc); err != nil {
			t.Fatalf("EMF line %q: %v", line, err)
		}
		if doc.AWS.Timestamp != now.UnixMilli() || doc.Function != "counter" || len(doc.AWS.CloudWatchMetrics) != 1 {
			t.Fatalf("EMF line %q: wrong timestamp, dimension value or directive count", line)
		}
		d := doc.AWS.CloudWatchMetrics[0]
		if d.Namespace != "svp-lab-sls" || len(d.Dimensions) != 1 || len(d.Dimensions[0]) != 1 ||
			d.Dimensions[0][0] != "Function" || len(d.Metrics) != 1 {
			t.Fatalf("EMF line %q: wrong namespace, dimensions or metrics", line)
		}
		m := d.Metrics[0]
		wantUnit := map[string]string{"EndToEndLatencyMs": "Milliseconds", "DuplicatesSkipped": "Count"}[m.Name]
		if wantUnit == "" || m.Unit != wantUnit {
			t.Fatalf("EMF line %q: metric %s with unit %s", line, m.Name, m.Unit)
		}
		var values map[string]any
		if err := json.Unmarshal([]byte(line), &values); err != nil {
			t.Fatal(err)
		}
		v, ok := values[m.Name].(float64)
		if !ok {
			t.Fatalf("EMF line %q: no value for %s", line, m.Name)
		}
		got[m.Name] = append(got[m.Name], v)
	}
	return got
}

func TestCountsOneView(t *testing.T) {
	db := newFakeDB()
	var metrics bytes.Buffer
	resp, err := newHandler(db, &metrics).Handle(context.Background(),
		events.SQSEvent{Records: []events.SQSMessage{view("m1", "req-1", videoA)}})
	if err != nil {
		t.Fatal(err)
	}
	if got := failures(t, resp); len(got) != 0 {
		t.Errorf("failures = %v, want none", got)
	}
	if got := db.views(t, videoA); got != 1 {
		t.Errorf("views = %d, want 1", got)
	}
	exp := db.items["event#req-1"]["expires_at"].(*types.AttributeValueMemberN).Value
	if want := strconv.FormatInt(now.Add(5*24*time.Hour).Unix(), 10); exp != want {
		t.Errorf("expires_at = %s, want %s", exp, want)
	}
	m := emfLines(t, &metrics)
	if got := m["EndToEndLatencyMs"]; len(got) != 1 || got[0] != 1500 {
		t.Errorf("EndToEndLatencyMs = %v, want [1500]", got)
	}
	if got := m["DuplicatesSkipped"]; len(got) != 1 || got[0] != 0 {
		t.Errorf("DuplicatesSkipped = %v, want [0]", got)
	}
}

func TestDuplicateCountsOnce(t *testing.T) {
	db := newFakeDB()
	var metrics bytes.Buffer
	h := newHandler(db, &metrics)
	// Same event twice in one batch, then again in a later batch: at-least-once delivery.
	resp, _ := h.Handle(context.Background(), events.SQSEvent{Records: []events.SQSMessage{
		view("m1", "req-1", videoA), view("m2", "req-1", videoA),
	}})
	resp2, _ := h.Handle(context.Background(), events.SQSEvent{Records: []events.SQSMessage{view("m3", "req-1", videoA)}})
	if got := append(failures(t, resp), failures(t, resp2)...); len(got) != 0 {
		t.Errorf("failures = %v, want none: a duplicate is done", got)
	}
	if got := db.views(t, videoA); got != 1 {
		t.Errorf("views = %d, want 1", got)
	}
	m := emfLines(t, &metrics)
	if got := m["DuplicatesSkipped"]; len(got) != 2 || got[0] != 1 || got[1] != 1 {
		t.Errorf("DuplicatesSkipped = %v, want [1 1]", got)
	}
	if got := m["EndToEndLatencyMs"]; len(got) != 1 {
		t.Errorf("EndToEndLatencyMs = %v, want one value: duplicates are not counted views", got)
	}
}

func TestTransientErrorsRetry(t *testing.T) {
	tests := map[string]error{
		"transaction conflict": &types.TransactionCanceledException{CancellationReasons: []types.CancellationReason{
			{Code: aws.String("TransactionConflict")}, {Code: aws.String("None")},
		}},
		"throttled in transaction": &types.TransactionCanceledException{CancellationReasons: []types.CancellationReason{
			{Code: aws.String("None")}, {Code: aws.String("ThrottlingError")},
		}},
		"no reasons":    &types.TransactionCanceledException{},
		"throughput":    &types.ProvisionedThroughputExceededException{},
		"other failure": errors.New("connection reset"),
	}
	for name, dbErr := range tests {
		t.Run(name, func(t *testing.T) {
			db := newFakeDB()
			db.failNext = dbErr
			var metrics bytes.Buffer
			h := newHandler(db, &metrics)
			resp, _ := h.Handle(context.Background(), events.SQSEvent{Records: []events.SQSMessage{view("m1", "req-1", videoA)}})
			if got := failures(t, resp); len(got) != 1 || got[0] != "m1" {
				t.Fatalf("failures = %v, want [m1]", got)
			}
			if got := emfLines(t, &metrics)["DuplicatesSkipped"]; len(got) != 1 || got[0] != 0 {
				t.Errorf("DuplicatesSkipped = %v, want [0]", got)
			}
			// The redelivery succeeds and counts the view once.
			resp, _ = h.Handle(context.Background(), events.SQSEvent{Records: []events.SQSMessage{view("m1", "req-1", videoA)}})
			if got := failures(t, resp); len(got) != 0 {
				t.Errorf("redelivery failures = %v, want none", got)
			}
			if got := db.views(t, videoA); got != 1 {
				t.Errorf("views = %d, want 1", got)
			}
		})
	}
}

func TestMalformedRecords(t *testing.T) {
	tests := map[string]events.SQSMessage{
		"no event_id":       message("m1", "", `{"video_id":"`+videoA+`"}`),
		"body not JSON":     message("m1", "req-1", `video_id=`+videoA),
		"video_id not UUID": message("m1", "req-1", `{"video_id":"42"}`),
		"video_id missing":  message("m1", "req-1", `{}`),
		"event_id empty str": func() events.SQSMessage {
			m := message("m1", "", `{"video_id":"`+videoA+`"}`)
			m.MessageAttributes["event_id"] = events.SQSMessageAttribute{StringValue: aws.String(""), DataType: "String"}
			return m
		}(),
	}
	for name, msg := range tests {
		t.Run(name, func(t *testing.T) {
			db := newFakeDB()
			resp, _ := newHandler(db, io.Discard).Handle(context.Background(), events.SQSEvent{Records: []events.SQSMessage{msg}})
			if got := failures(t, resp); len(got) != 1 || got[0] != "m1" {
				t.Errorf("failures = %v, want [m1]", got)
			}
			if db.calls != 0 {
				t.Errorf("DynamoDB calls = %d, want 0 for a malformed record", db.calls)
			}
		})
	}
}

func TestMixedBatch(t *testing.T) {
	db := newFakeDB()
	db.items["event#req-dup"] = map[string]types.AttributeValue{}
	var metrics bytes.Buffer
	h := newHandler(db, &metrics)
	resp, err := h.Handle(context.Background(), events.SQSEvent{Records: []events.SQSMessage{
		view("ok-1", "req-1", videoA),
		message("bad-json", "req-2", "{"),
		view("dup", "req-dup", videoA),
		view("ok-2", "req-3", videoB),
		view("no-event", "", videoB),
		view("ok-3", "req-4", strings.ToUpper(videoA)),
	}})
	if err != nil {
		t.Fatal(err)
	}
	got := failures(t, resp)
	if strings.Join(got, ",") != "bad-json,no-event" {
		t.Errorf("failures = %v, want [bad-json no-event]", got)
	}
	if a, b := db.views(t, videoA), db.views(t, videoB); a != 2 || b != 1 {
		t.Errorf("views = %d, %d; want 2, 1", a, b)
	}
	m := emfLines(t, &metrics)
	if got := m["DuplicatesSkipped"]; len(got) != 1 || got[0] != 1 {
		t.Errorf("DuplicatesSkipped = %v, want [1]", got)
	}
	if got := m["EndToEndLatencyMs"]; len(got) != 3 {
		t.Errorf("EndToEndLatencyMs = %v, want 3 values", got)
	}
}

func TestEmptyBatch(t *testing.T) {
	db := newFakeDB()
	var metrics bytes.Buffer
	resp, err := newHandler(db, &metrics).Handle(context.Background(), events.SQSEvent{})
	if err != nil {
		t.Fatal(err)
	}
	if resp.BatchItemFailures == nil || len(resp.BatchItemFailures) != 0 {
		t.Errorf("BatchItemFailures = %#v, want an empty list", resp.BatchItemFailures)
	}
	if db.calls != 0 || metrics.Len() != 0 {
		t.Errorf("calls = %d, metrics = %q; want none", db.calls, metrics.String())
	}
}

func TestResponseJSON(t *testing.T) {
	resp, _ := newHandler(newFakeDB(), io.Discard).Handle(context.Background(),
		events.SQSEvent{Records: []events.SQSMessage{message("m1", "", "{}")}})
	b, err := json.Marshal(resp)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != `{"batchItemFailures":[{"itemIdentifier":"m1"}]}` {
		t.Errorf("response JSON = %s", b)
	}
}
