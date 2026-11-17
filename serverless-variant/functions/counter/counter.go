// Package counter is the SQS consumer that counts video views in DynamoDB exactly once per view event.
//
// SQS standard queues deliver a message at least once and in any order, so each record writes, in one
// transaction, a dedupe item keyed by its event id (put only if absent) and the increment of the video's counter.
// A redelivered event fails the put's condition, cancels the transaction and is skipped, so it never counts twice.
// Records that fail for any other reason go back to the queue through the partial batch response, and the queue's
// redrive policy moves a record that keeps failing to its dead-letter queue.
package counter

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"strconv"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"

	"github.com/anhnvcoder/svp-labs/serverless-variant/functions/internal/videoid"
)

// Metric names and the namespace of the CloudWatch embedded metric format (EMF) lines the handler prints.
const (
	MetricNamespace     = "svp-lab-sls"
	MetricFunction      = "counter"
	MetricLatency       = "EndToEndLatencyMs"
	MetricDuplicates    = "DuplicatesSkipped"
	eventIDAttribute    = "event_id"
	sentTimestampSQSKey = "SentTimestamp"
	conditionFailedCode = "ConditionalCheckFailed"
)

// TransactWriter is the part of the DynamoDB client the handler uses; *dynamodb.Client satisfies it.
type TransactWriter interface {
	TransactWriteItems(ctx context.Context, in *dynamodb.TransactWriteItemsInput,
		optFns ...func(*dynamodb.Options)) (*dynamodb.TransactWriteItemsOutput, error)
}

// Handler counts the views of one SQS batch.
type Handler struct {
	// DB writes the transactions.
	DB TransactWriter
	// Table is the name of the views table.
	Table string
	// DedupeTTL is how long a dedupe item lives; it must outlast the queue's retention so that no redelivery
	// finds its item expired.
	DedupeTTL time.Duration
	// Now returns the current time.
	Now func() time.Time
	// Metrics receives one EMF JSON line per metric record.
	Metrics io.Writer
	// Log receives the structured logs.
	Log *slog.Logger
}

// body is the JSON body of a view message.
type body struct {
	VideoID string `json:"video_id"`
}

type outcome int

const (
	counted outcome = iota
	duplicate
)

// Handle counts each record of ev once and returns the message ids of the records to deliver again: malformed
// records and records whose write failed. It never returns an error, so one bad record does not fail the batch.
func (h *Handler) Handle(ctx context.Context, ev events.SQSEvent) (events.SQSEventResponse, error) {
	resp := events.SQSEventResponse{BatchItemFailures: []events.SQSBatchItemFailure{}}
	duplicates := 0
	for _, rec := range ev.Records {
		res, err := h.handleRecord(ctx, rec)
		if err != nil {
			h.Log.WarnContext(ctx, "record not counted", "message_id", rec.MessageId, "error", err)
			resp.BatchItemFailures = append(resp.BatchItemFailures,
				events.SQSBatchItemFailure{ItemIdentifier: rec.MessageId})
			continue
		}
		if res == duplicate {
			duplicates++
			h.Log.InfoContext(ctx, "duplicate view skipped", "message_id", rec.MessageId)
			continue
		}
		if sent, ok := sentTime(rec); ok {
			h.emit(MetricLatency, "Milliseconds", float64(h.Now().Sub(sent).Milliseconds()))
		}
	}
	if len(ev.Records) > 0 {
		h.emit(MetricDuplicates, "Count", float64(duplicates))
	}
	return resp, nil
}

func (h *Handler) handleRecord(ctx context.Context, rec events.SQSMessage) (outcome, error) {
	attr, ok := rec.MessageAttributes[eventIDAttribute]
	if !ok || attr.StringValue == nil || *attr.StringValue == "" {
		return 0, errors.New("message attribute event_id is missing")
	}
	eventID := *attr.StringValue
	var b body
	if err := json.Unmarshal([]byte(rec.Body), &b); err != nil {
		return 0, fmt.Errorf("body is not JSON: %w", err)
	}
	id, ok := videoid.Parse(b.VideoID)
	if !ok {
		return 0, errors.New("video_id is not a UUID")
	}

	expiresAt := h.Now().Add(h.DedupeTTL).Unix()
	_, err := h.DB.TransactWriteItems(ctx, &dynamodb.TransactWriteItemsInput{
		TransactItems: []types.TransactWriteItem{
			{Put: &types.Put{
				TableName: aws.String(h.Table),
				Item: map[string]types.AttributeValue{
					"pk":         &types.AttributeValueMemberS{Value: "event#" + eventID},
					"expires_at": &types.AttributeValueMemberN{Value: strconv.FormatInt(expiresAt, 10)},
				},
				ConditionExpression: aws.String("attribute_not_exists(pk)"),
			}},
			// VIEWS is a DynamoDB reserved word, so the attribute goes through a name placeholder.
			{Update: &types.Update{
				TableName:                 aws.String(h.Table),
				Key:                       map[string]types.AttributeValue{"pk": &types.AttributeValueMemberS{Value: "video#" + id}},
				UpdateExpression:          aws.String("ADD #views :one"),
				ExpressionAttributeNames:  map[string]string{"#views": "views"},
				ExpressionAttributeValues: map[string]types.AttributeValue{":one": &types.AttributeValueMemberN{Value: "1"}},
			}},
		},
	})
	if err == nil {
		return counted, nil
	}
	if isDuplicate(err) {
		return duplicate, nil
	}
	return 0, fmt.Errorf("transact write: %w", err)
}

// isDuplicate reports whether err is a cancelled transaction whose dedupe put, the first item, failed its
// condition. Any other reason (a conflict with a concurrent transaction, throttling) is transient.
func isDuplicate(err error) bool {
	var canceled *types.TransactionCanceledException
	if !errors.As(err, &canceled) || len(canceled.CancellationReasons) == 0 {
		return false
	}
	return aws.ToString(canceled.CancellationReasons[0].Code) == conditionFailedCode
}

func sentTime(rec events.SQSMessage) (time.Time, bool) {
	ms, err := strconv.ParseInt(rec.Attributes[sentTimestampSQSKey], 10, 64)
	if err != nil {
		return time.Time{}, false
	}
	return time.UnixMilli(ms), true
}

// emit prints one EMF line: CloudWatch Logs extracts the metric from it, with no API call from the function.
func (h *Handler) emit(name, unit string, value float64) {
	line := map[string]any{
		"_aws": map[string]any{
			"Timestamp": h.Now().UnixMilli(),
			"CloudWatchMetrics": []map[string]any{{
				"Namespace":  MetricNamespace,
				"Dimensions": [][]string{{"Function"}},
				"Metrics":    []map[string]string{{"Name": name, "Unit": unit}},
			}},
		},
		"Function": MetricFunction,
		name:       value,
	}
	b, err := json.Marshal(line)
	if err != nil {
		h.Log.Error("encode metric", "metric", name, "error", err)
		return
	}
	if _, err := h.Metrics.Write(append(b, '\n')); err != nil {
		h.Log.Error("write metric", "metric", name, "error", err)
	}
}
