// Package transcode is the transcode task of the upload state machine. It stands in for a real transcode: it checks
// the uploaded object's key and returns where the HLS playlist would be, without calling any AWS service.
package transcode

import (
	"context"
	"path"
	"strings"

	"github.com/anhnvcoder/svp-labs/serverless-variant/functions/internal/videoid"
)

// Input is the task input the state machine builds from the S3 event: the key of the uploaded object.
type Input struct {
	SourceKey string `json:"source_key"`
}

// Output is the task result: the video, its upload and the key of the HLS master playlist.
type Output struct {
	VideoID     string `json:"video_id"`
	SourceKey   string `json:"source_key"`
	PlaylistKey string `json:"playlist_key"`
}

// InvalidInput is the error for an input that no retry can fix. The Lambda runtime reports an error by the name of
// its type, so the state machine catches this one as "InvalidInput"; return it unwrapped to keep that name.
type InvalidInput struct {
	Reason string
}

func (e *InvalidInput) Error() string { return "invalid input: " + e.Reason }

const uploadPrefix = "uploads/"

// allowedExtensions holds the upload extensions in lower case; the check ignores case.
var allowedExtensions = map[string]bool{".mp4": true, ".mov": true}

// Handle checks that in.SourceKey is uploads/<video id>.<mp4|mov> and returns the playlist key of that video.
// Any other input returns *InvalidInput.
func Handle(_ context.Context, in Input) (Output, error) {
	if in.SourceKey == "" {
		return Output{}, &InvalidInput{Reason: "source_key is missing"}
	}
	name, ok := strings.CutPrefix(in.SourceKey, uploadPrefix)
	if !ok {
		return Output{}, &InvalidInput{Reason: "source_key is not under " + uploadPrefix}
	}
	ext := path.Ext(name)
	if !allowedExtensions[strings.ToLower(ext)] {
		return Output{}, &InvalidInput{Reason: "source_key extension is not .mp4 or .mov"}
	}
	id, ok := videoid.Parse(strings.TrimSuffix(name, ext))
	if !ok {
		return Output{}, &InvalidInput{Reason: "source_key does not name a video id"}
	}
	return Output{
		VideoID:     id,
		SourceKey:   in.SourceKey,
		PlaylistKey: "hls/" + id + "/master.m3u8",
	}, nil
}
