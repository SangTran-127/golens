package lsp

import (
	"bytes"
	"errors"
	"sort"
	"unicode/utf8"
)

var errEditOutOfRange = errors.New("edit out of range")

type FileBuffer struct {
	Content    []byte
	LineStarts []int32
}

func NewFileBuffer(content []byte) *FileBuffer {
	b := &FileBuffer{Content: append(make([]byte, 0, len(content)+len(content)/4), content...)}
	b.LineStarts = appendLineStarts(make([]int32, 1, bytes.Count(content, []byte{'\n'})+1), content, 0)
	return b
}

func appendLineStarts(starts []int32, chunk []byte, base int) []int32 {
	for {
		i := bytes.IndexByte(chunk, '\n')
		if i < 0 {
			return starts
		}
		base += i + 1
		starts = append(starts, int32(base))
		chunk = chunk[i+1:]
	}
}

func (b *FileBuffer) Splice(start, end int, repl []byte) error {
	if start < 0 || end < start || end > len(b.Content) {
		return errEditOutOfRange
	}
	delta := len(repl) - (end - start)
	oldLen := len(b.Content)
	newLen := oldLen + delta
	if delta > 0 {
		if newLen > cap(b.Content) {
			grown := make([]byte, oldLen, newLen+newLen/4)
			copy(grown, b.Content)
			b.Content = grown
		}
		b.Content = b.Content[:newLen]
		copy(b.Content[end+delta:], b.Content[end:oldLen])
	} else if delta < 0 {
		copy(b.Content[end+delta:], b.Content[end:])
		b.Content = b.Content[:newLen]
		if cap(b.Content) > 64<<10 && cap(b.Content) > 2*newLen {
			b.Content = append(make([]byte, 0, newLen+newLen/4), b.Content...)
		}
	}
	copy(b.Content[start:], repl)
	b.patchLineStarts(start, end, repl, delta)
	return nil
}

func (b *FileBuffer) patchLineStarts(start, end int, repl []byte, delta int) {
	ls := b.LineStarts
	lo := sort.Search(len(ls), func(i int) bool { return int(ls[i]) > start })
	hi := sort.Search(len(ls), func(i int) bool { return int(ls[i]) > end })
	added := bytes.Count(repl, []byte{'\n'})
	removed := hi - lo
	if d := added - removed; d > 0 {
		ls = append(ls, make([]int32, d)...)
		copy(ls[hi+d:], ls[hi:len(ls)-d])
	} else if d < 0 {
		copy(ls[hi+d:], ls[hi:])
		ls = ls[:len(ls)+d]
	}
	newHi := lo + added
	for i := newHi; i < len(ls); i++ {
		ls[i] += int32(delta)
	}
	w := lo
	chunk := repl
	base := start
	for {
		i := bytes.IndexByte(chunk, '\n')
		if i < 0 {
			break
		}
		base += i + 1
		ls[w] = int32(base)
		w++
		chunk = chunk[i+1:]
	}
	b.LineStarts = ls
}

func (b *FileBuffer) lineOf(offset int) int {
	ls := b.LineStarts
	return sort.Search(len(ls), func(i int) bool { return int(ls[i]) > offset }) - 1
}

func (b *FileBuffer) Position(offset int) (line, col int) {
	if offset < 0 {
		offset = 0
	}
	if offset > len(b.Content) {
		offset = len(b.Content)
	}
	line = b.lineOf(offset)
	return line, utf16Len(b.Content[b.LineStarts[line]:offset])
}

func (b *FileBuffer) Offset(line, col int) int {
	if line < 0 {
		return 0
	}
	if line >= len(b.LineStarts) {
		return len(b.Content)
	}
	start := int(b.LineStarts[line])
	end := len(b.Content)
	if line+1 < len(b.LineStarts) {
		end = int(b.LineStarts[line+1]) - 1
	}
	return start + utf16OffsetToByteOffset(b.Content[start:end], col)
}

func utf16Len(b []byte) int {
	n := 0
	for len(b) > 0 {
		c := b[0]
		if c < utf8.RuneSelf {
			n++
			b = b[1:]
			continue
		}
		r, size := utf8.DecodeRune(b)
		if r > 0xFFFF {
			n += 2
		} else {
			n++
		}
		b = b[size:]
	}
	return n
}

func utf16OffsetToByteOffset(lineBytes []byte, utf16Col int) int {
	if utf16Col <= 0 {
		return 0
	}
	u, i := 0, 0
	for i < len(lineBytes) && u < utf16Col {
		if lineBytes[i] < utf8.RuneSelf {
			u++
			i++
			continue
		}
		r, size := utf8.DecodeRune(lineBytes[i:])
		if r > 0xFFFF {
			u += 2
		} else {
			u++
		}
		i += size
	}
	return i
}
