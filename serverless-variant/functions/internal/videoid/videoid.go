// Package videoid checks the video id that both Lambda functions read: a UUID in its 8-4-4-4-12 hex form.
package videoid

import (
	"regexp"
	"strings"
)

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// Parse reports whether s is a UUID and returns it in lower case, so that the same video always maps to the same
// DynamoDB key and object key whatever case the caller used.
func Parse(s string) (string, bool) {
	if !uuidPattern.MatchString(s) {
		return "", false
	}
	return strings.ToLower(s), true
}
