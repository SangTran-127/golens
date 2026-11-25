package lsp

import (
	"bytes"
	"math/rand"
	"testing"
)

func naiveStarts(b []byte) []int32 {
	s := []int32{0}
	for i, c := range b {
		if c == '\n' {
			s = append(s, int32(i+1))
		}
	}
	return s
}

func checkBuffer(t *testing.T, b *FileBuffer, want []byte) {
	t.Helper()
	if !bytes.Equal(b.Content, want) {
		t.Fatalf("content mismatch:\n got %q\nwant %q", b.Content, want)
	}
	ws := naiveStarts(want)
	if len(ws) != len(b.LineStarts) {
		t.Fatalf("line starts len %d want %d (%v vs %v)", len(b.LineStarts), len(ws), b.LineStarts, ws)
	}
	for i := range ws {
		if ws[i] != b.LineStarts[i] {
			t.Fatalf("line start %d = %d want %d", i, b.LineStarts[i], ws[i])
		}
	}
}

func splice(s []byte, start, end int, repl []byte) []byte {
	out := append([]byte{}, s[:start]...)
	out = append(out, repl...)
	return append(out, s[end:]...)
}

func TestSpliceCases(t *testing.T) {
	cases := []struct {
		name       string
		init       string
		start, end int
		repl       string
	}{
		{"insert ascii", "hello\nworld\n", 5, 5, "!"},
		{"insert newline", "hello\nworld\n", 2, 2, "\n"},
		{"delete newline", "hello\nworld\n", 5, 6, ""},
		{"replace across lines", "a\nb\nc\nd\n", 1, 6, "X\nY"},
		{"insert at start", "abc\n", 0, 0, "\n\n"},
		{"insert at end", "abc", 3, 3, "\ndef"},
		{"delete all", "a\nb\nc", 0, 5, ""},
		{"multibyte", "héllo\n日本語\n", 7, 10, "x"},
		{"emoji", "a\U0001F44Bb\nc", 1, 5, "\n"},
		{"crlf insert", "a\r\nb\r\nc", 3, 3, "x\r\n"},
		{"crlf delete pair", "a\r\nb\r\nc", 1, 3, ""},
		{"empty doc", "", 0, 0, "x\ny"},
		{"replace newline with newline", "a\nb", 1, 2, "\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			b := NewFileBuffer([]byte(c.init))
			if err := b.Splice(c.start, c.end, []byte(c.repl)); err != nil {
				t.Fatal(err)
			}
			checkBuffer(t, b, splice([]byte(c.init), c.start, c.end, []byte(c.repl)))
		})
	}
}

func TestSpliceRejectsOutOfRange(t *testing.T) {
	b := NewFileBuffer([]byte("abc"))
	for _, r := range [][2]int{{-1, 0}, {2, 1}, {0, 4}} {
		if err := b.Splice(r[0], r[1], nil); err == nil {
			t.Fatalf("expected error for %v", r)
		}
	}
	checkBuffer(t, b, []byte("abc"))
}

func TestSpliceFuzzAgainstNaive(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	alphabet := [][]byte{[]byte("a"), []byte("\n"), []byte("\r\n"), []byte("é"), []byte("日"), []byte("\U0001F44B"), []byte(" "), []byte("{}")}
	for round := 0; round < 200; round++ {
		var doc []byte
		for i := rng.Intn(200); i > 0; i-- {
			doc = append(doc, alphabet[rng.Intn(len(alphabet))]...)
		}
		b := NewFileBuffer(doc)
		for step := 0; step < 100; step++ {
			start := rng.Intn(len(doc) + 1)
			end := start + rng.Intn(len(doc)-start+1)
			if rng.Intn(3) == 0 {
				end = start
			}
			var repl []byte
			for i := rng.Intn(6); i > 0; i-- {
				repl = append(repl, alphabet[rng.Intn(len(alphabet))]...)
			}
			if err := b.Splice(start, end, repl); err != nil {
				t.Fatal(err)
			}
			doc = splice(doc, start, end, repl)
			checkBuffer(t, b, doc)
		}
	}
}

func TestPositionOffsetRoundTrip(t *testing.T) {
	b := NewFileBuffer([]byte("ab\nhé日\U0001F44Bx\r\nlast"))
	cases := []struct{ off, line, col int }{
		{0, 0, 0}, {2, 0, 2}, {3, 1, 0}, {4, 1, 1}, {6, 1, 2}, {9, 1, 3}, {13, 1, 5}, {14, 1, 6}, {16, 2, 0}, {20, 2, 4},
	}
	for _, c := range cases {
		l, col := b.Position(c.off)
		if l != c.line || col != c.col {
			t.Errorf("Position(%d) = %d,%d want %d,%d", c.off, l, col, c.line, c.col)
		}
		if o := b.Offset(c.line, c.col); o != c.off {
			t.Errorf("Offset(%d,%d) = %d want %d", c.line, c.col, o, c.off)
		}
	}
	if o := b.Offset(0, 99); o != 2 {
		t.Errorf("Offset clamps to line end: got %d", o)
	}
	if o := b.Offset(9, 0); o != len(b.Content) {
		t.Errorf("Offset past last line: got %d", o)
	}
}

func makeDoc(size int) []byte {
	line := []byte("\tfmt.Println(\"hello, world\", value, other) // comment\n")
	var buf bytes.Buffer
	for buf.Len() < size {
		buf.Write(line)
	}
	return buf.Bytes()
}

func TestSpliceAllocatesNothingOnKeystroke(t *testing.T) {
	b := NewFileBuffer(makeDoc(100 << 10))
	mid := len(b.Content) / 2
	ch := []byte("x")
	allocs := testing.AllocsPerRun(1000, func() {
		_ = b.Splice(mid, mid, ch)
		_ = b.Splice(mid, mid+1, nil)
	})
	if allocs != 0 {
		t.Fatalf("splice allocated %.1f objects per keystroke", allocs)
	}
}

func benchSplice(bm *testing.B, size int) {
	b := NewFileBuffer(makeDoc(size))
	mid := len(b.Content) / 2
	ch := []byte("x")
	bm.ReportAllocs()
	bm.ResetTimer()
	for i := 0; i < bm.N; i++ {
		_ = b.Splice(mid, mid, ch)
		_ = b.Splice(mid, mid+1, nil)
	}
}

func BenchmarkSplice10KB(b *testing.B)  { benchSplice(b, 10<<10) }
func BenchmarkSplice100KB(b *testing.B) { benchSplice(b, 100<<10) }
func BenchmarkSplice1MB(b *testing.B)   { benchSplice(b, 1<<20) }
