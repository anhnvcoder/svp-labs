package videoid

import "testing"

func TestParse(t *testing.T) {
	tests := []struct {
		in     string
		want   string
		wantOK bool
	}{
		{"0b7e4a52-3c1d-4f7a-9e2b-5d6c7f8a9b0c", "0b7e4a52-3c1d-4f7a-9e2b-5d6c7f8a9b0c", true},
		{"0B7E4A52-3C1D-4F7A-9E2B-5D6C7F8A9B0C", "0b7e4a52-3c1d-4f7a-9e2b-5d6c7f8a9b0c", true},
		{"", "", false},
		{"not-a-uuid", "", false},
		{"0b7e4a523c1d4f7a9e2b5d6c7f8a9b0c", "", false},
		{"0b7e4a52-3c1d-4f7a-9e2b-5d6c7f8a9b0c ", "", false},
		{"0b7e4a52-3c1d-4f7a-9e2b-5d6c7f8a9b0g", "", false},
	}
	for _, tt := range tests {
		got, ok := Parse(tt.in)
		if got != tt.want || ok != tt.wantOK {
			t.Errorf("Parse(%q) = %q, %v; want %q, %v", tt.in, got, ok, tt.want, tt.wantOK)
		}
	}
}
