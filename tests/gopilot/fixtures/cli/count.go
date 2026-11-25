package main

import (
	"bufio"
	"io"
	"strings"
)

type Stats struct {
	Lines int
	Words int
}

func Count(r io.Reader) (Stats, error) {
	var s Stats
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		s.Lines++
		s.Words += len(strings.Fields(sc.Text()))
	}
	return s, sc.Err()
}
