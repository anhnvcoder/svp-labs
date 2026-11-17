package transcode

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"testing"
)

const id = "0b7e4a52-3c1d-4f7a-9e2b-5d6c7f8a9b0c"

func TestHandleValid(t *testing.T) {
	tests := []struct {
		key  string
		want Output
	}{
		{"uploads/" + id + ".mp4", Output{id, "uploads/" + id + ".mp4", "hls/" + id + "/master.m3u8"}},
		{"uploads/" + id + ".MOV", Output{id, "uploads/" + id + ".MOV", "hls/" + id + "/master.m3u8"}},
		{"uploads/0B7E4A52-3C1D-4F7A-9E2B-5D6C7F8A9B0C.mov",
			Output{id, "uploads/0B7E4A52-3C1D-4F7A-9E2B-5D6C7F8A9B0C.mov", "hls/" + id + "/master.m3u8"}},
	}
	for _, tt := range tests {
		got, err := Handle(context.Background(), Input{SourceKey: tt.key})
		if err != nil {
			t.Fatalf("Handle(%q) error = %v", tt.key, err)
		}
		if got != tt.want {
			t.Errorf("Handle(%q) = %+v, want %+v", tt.key, got, tt.want)
		}
	}
}

func TestHandleInvalid(t *testing.T) {
	keys := map[string]string{
		"missing":       "",
		"wrong ext":     "uploads/" + id + ".avi",
		"no ext":        "uploads/" + id,
		"not uploads":   "raw/" + id + ".mp4",
		"nested":        "uploads/x/" + id + ".mp4",
		"not a uuid":    "uploads/clip.mp4",
		"double ext":    "uploads/" + id + ".mp4.mov",
		"ext only name": "uploads/.mp4",
	}
	for name, key := range keys {
		_, err := Handle(context.Background(), Input{SourceKey: key})
		var invalid *InvalidInput
		if !errors.As(err, &invalid) {
			t.Errorf("%s: Handle(%q) error = %v, want *InvalidInput", name, key, err)
		}
	}
}

// The state machine's Catch matches the error name the Lambda runtime derives from the error's type.
func TestInvalidInputName(t *testing.T) {
	_, err := Handle(context.Background(), Input{})
	typ := reflect.TypeOf(err)
	if typ.Kind() == reflect.Pointer {
		typ = typ.Elem()
	}
	if typ.Name() != "InvalidInput" {
		t.Errorf("error type name = %q, want InvalidInput", typ.Name())
	}
}

func TestContractJSON(t *testing.T) {
	var in Input
	if err := json.Unmarshal([]byte(`{"source_key":"uploads/`+id+`.mp4"}`), &in); err != nil {
		t.Fatal(err)
	}
	out, err := Handle(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"video_id":"` + id + `","source_key":"uploads/` + id + `.mp4","playlist_key":"hls/` + id + `/master.m3u8"}`
	if string(b) != want {
		t.Errorf("output JSON = %s, want %s", b, want)
	}
}
