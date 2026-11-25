package database

import (
	"encoding/binary"
	"encoding/hex"
	"errors"
	"unicode/utf8"
)

const (
	KindUnknown uint8 = iota
	KindText
	KindInt
	KindFloat
	KindDecimal
	KindBool
	KindDateTime
	KindJSON
	KindBinary
	KindUUID
)

const (
	PageFlagEnd    uint8 = 1
	PageFlagSorted uint8 = 2

	pageHeaderSize  = 24
	DisplayMaxBytes = 512
	pageVersion     = 1
)

var kindNames = [...]string{"unknown", "text", "int", "float", "decimal", "bool", "datetime", "json", "binary", "uuid"}

func KindName(k uint8) string {
	if int(k) < len(kindNames) {
		return kindNames[k]
	}
	return "unknown"
}

type cellFunc func(row, col int) (value []byte, null bool)

func pad4(n int) int { return (n + 3) &^ 3 }

func displayText(kind uint8, v []byte, scratch []byte) ([]byte, bool) {
	if kind == KindBinary {
		n := len(v)
		limit := (DisplayMaxBytes - 2) / 2
		cut := n > limit
		if cut {
			n = limit
		}
		scratch = append(scratch[:0], '0', 'x')
		scratch = hex.AppendEncode(scratch, v[:n])
		return scratch, cut
	}
	if len(v) <= DisplayMaxBytes {
		return v, false
	}
	end := DisplayMaxBytes
	for end > 0 && !utf8.RuneStart(v[end]) {
		end--
	}
	return v[:end], true
}

func encodePage(firstRow int64, flags uint8, version uint32, kinds []uint8, rows int, cell cellFunc) []byte {
	bitmap := pad4((rows + 7) / 8)
	size := pageHeaderSize
	for range kinds {
		size += 4 + 2*bitmap + 4*(rows+1) + 16*rows
	}
	buf := make([]byte, pageHeaderSize, size)
	copy(buf, "GLRP")
	buf[4] = pageVersion
	buf[5] = flags
	binary.LittleEndian.PutUint16(buf[6:], uint16(len(kinds)))
	binary.LittleEndian.PutUint64(buf[8:], uint64(firstRow))
	binary.LittleEndian.PutUint32(buf[16:], uint32(rows))
	binary.LittleEndian.PutUint32(buf[20:], version)
	var scratch []byte
	for c, kind := range kinds {
		buf = append(buf, kind, 0, 0, 0)
		nullAt := len(buf)
		buf = append(buf, make([]byte, 2*bitmap+4*(rows+1))...)
		truncAt := nullAt + bitmap
		offAt := truncAt + bitmap
		dataAt := len(buf)
		for r := 0; r < rows; r++ {
			v, null := cell(r, c)
			if null {
				buf[nullAt+r/8] |= 1 << (r % 8)
			} else {
				text, cut := displayText(kind, v, scratch)
				if kind == KindBinary {
					scratch = text
				}
				if cut {
					buf[truncAt+r/8] |= 1 << (r % 8)
				}
				buf = append(buf, text...)
			}
			binary.LittleEndian.PutUint32(buf[offAt+4*(r+1):], uint32(len(buf)-dataAt))
		}
		for len(buf)%4 != 0 {
			buf = append(buf, 0)
		}
	}
	return buf
}

type DecodedColumn struct {
	Kind      uint8
	Nulls     []bool
	Truncated []bool
	Values    []string
}

type DecodedPage struct {
	Flags    uint8
	FirstRow int64
	Rows     int
	Version  uint32
	Columns  []DecodedColumn
}

var errBadPage = errors.New("malformed page")

func DecodePage(b []byte) (*DecodedPage, error) {
	if len(b) < pageHeaderSize || string(b[:4]) != "GLRP" || b[4] != pageVersion {
		return nil, errBadPage
	}
	p := &DecodedPage{
		Flags:    b[5],
		FirstRow: int64(binary.LittleEndian.Uint64(b[8:])),
		Rows:     int(binary.LittleEndian.Uint32(b[16:])),
		Version:  binary.LittleEndian.Uint32(b[20:]),
	}
	cols := int(binary.LittleEndian.Uint16(b[6:]))
	if p.Rows < 0 || p.Rows > len(b) {
		return nil, errBadPage
	}
	bitmap := pad4((p.Rows + 7) / 8)
	at := pageHeaderSize
	for c := 0; c < cols; c++ {
		head := 4 + 2*bitmap + 4*(p.Rows+1)
		if at+head > len(b) {
			return nil, errBadPage
		}
		col := DecodedColumn{Kind: b[at], Nulls: make([]bool, p.Rows), Truncated: make([]bool, p.Rows), Values: make([]string, p.Rows)}
		nulls := b[at+4:]
		trunc := b[at+4+bitmap:]
		offs := b[at+4+2*bitmap:]
		data := at + head
		n := int(binary.LittleEndian.Uint32(offs[4*p.Rows:]))
		if data+n > len(b) || binary.LittleEndian.Uint32(offs) != 0 {
			return nil, errBadPage
		}
		for r := 0; r < p.Rows; r++ {
			s := int(binary.LittleEndian.Uint32(offs[4*r:]))
			e := int(binary.LittleEndian.Uint32(offs[4*(r+1):]))
			if s > e || e > n {
				return nil, errBadPage
			}
			col.Nulls[r] = nulls[r/8]&(1<<(r%8)) != 0
			col.Truncated[r] = trunc[r/8]&(1<<(r%8)) != 0
			col.Values[r] = string(b[data+s : data+e])
		}
		p.Columns = append(p.Columns, col)
		at = data + pad4(n)
	}
	if at != len(b) {
		return nil, errBadPage
	}
	return p, nil
}
