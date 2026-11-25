package main

import (
	"encoding/json"
	"fmt"
	"io"
)

func Render(w io.Writer, s Stats, asJSON bool) error {
	if asJSON {
		return json.NewEncoder(w).Encode(map[string]int{"lines": s.Lines, "words": s.Words})
	}
	_, err := fmt.Fprintf(w, "%d lines, %d words\n", s.Lines, s.Words)
	return err
}
