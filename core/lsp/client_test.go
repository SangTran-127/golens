package lsp

import "testing"

func TestUtf16OffsetToByteOffset(t *testing.T) {
	tests := []struct {
		input    string
		utf16Col int
		expected int
	}{
		{"hello", 2, 2},
		{"hello", 0, 0},
		{"hello", 10, 5},
		{"gopher日本語", 6, 6},
		{"gopher日本語", 7, 9},
		{"gopher日本語", 8, 12},
		{"gopher日本語", 9, 15},
		{"gopher日本語", 20, 15},
		{"\U0001F44Bgopher", 2, 4},
		{"\U0001F44Bgopher", 3, 5},
	}

	for _, tc := range tests {
		res := utf16OffsetToByteOffset([]byte(tc.input), tc.utf16Col)
		if res != tc.expected {
			t.Errorf("For %q and UTF-16 col %d, expected byte offset %d, got %d", tc.input, tc.utf16Col, tc.expected, res)
		}
	}
}
