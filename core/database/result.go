package database

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"math"
	"slices"
	"strconv"
	"sync"
	"time"
	"unicode/utf8"
)

type result struct {
	id        string
	sess      *session
	sp        *spool
	columns   []Column
	kinds     []uint8
	mu        sync.Mutex
	cur       cursor
	cancel    context.CancelFunc
	complete  bool
	truncated bool
	fetching  bool
	version   uint32
	perm      []int64
	firstPage []byte
	pageSize  int
	table     *tableBinding
}

func newResultID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return "r-" + hex.EncodeToString(b[:])
}

func newResult(s *session, cur cursor, pageSize int) *result {
	id := newResultID()
	return &result{id: id, sess: s, sp: newSpool(id, len(cur.columns())), cur: cur, kinds: cur.kinds(), pageSize: pageSize}
}

func (r *result) fill(target int64, start time.Time, progress func(int64)) (bool, time.Duration, error) {
	var firstRow time.Duration
	cur := r.cur
	if cur == nil {
		return true, 0, nil
	}
	have := r.sp.rowCount()
	for have < target {
		ch := newChunk(len(r.kinds))
		var more bool
		var err error
		for !ch.full() && have+int64(ch.rows) < target {
			more, err = cur.next(ch)
			if err != nil || !more {
				break
			}
			if firstRow == 0 {
				firstRow = time.Since(start)
			}
		}
		r.sp.commit(ch)
		have += int64(ch.rows)
		if progress != nil {
			progress(have)
		}
		if err != nil {
			return false, firstRow, err
		}
		if !more {
			return true, firstRow, nil
		}
	}
	return false, firstRow, nil
}

func (r *result) viewRows(first int64, n int) ([]int64, int64, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.perm != nil {
		total := int64(len(r.perm))
		if first >= total {
			return nil, total, true
		}
		end := min(total, first+int64(n))
		return append([]int64(nil), r.perm[first:end]...), total, true
	}
	total := r.sp.rowCount()
	if first >= total {
		return nil, total, false
	}
	end := min(total, first+int64(n))
	rows := make([]int64, 0, end-first)
	for i := first; i < end; i++ {
		rows = append(rows, i)
	}
	return rows, total, false
}

func (r *result) encode(first int64, n int) []byte {
	rows, total, sorted := r.viewRows(first, n)
	r.mu.Lock()
	open := r.cur != nil
	version := r.version
	r.mu.Unlock()
	refs, err := r.sp.refs(rows)
	if err != nil {
		refs = nil
		rows = nil
	}
	var flags uint8
	if sorted {
		flags |= PageFlagSorted
	}
	if (sorted || !open) && first+int64(len(rows)) >= total {
		flags |= PageFlagEnd
	}
	return encodePage(first, flags, version, r.kinds, len(refs), func(row, col int) ([]byte, bool) {
		ref := refs[row]
		return ref.cols[col].cell(ref.idx)
	})
}

func (r *result) page(first int64, n int) []byte {
	n = max(0, n)
	first = max(0, first)
	r.mu.Lock()
	if first == 0 && n == r.pageSize && r.firstPage != nil && r.perm == nil {
		b := r.firstPage
		r.mu.Unlock()
		return b
	}
	needCursor := r.perm == nil && r.cur != nil
	r.mu.Unlock()
	if needCursor && r.sp.rowCount() < first+int64(n) {
		r.readMore(first+int64(n), nil)
	}
	return r.encode(first, n)
}

func (r *result) readMore(target int64, progress func(int64)) *Error {
	s := r.sess
	s.mu.Lock()
	defer s.mu.Unlock()
	r.mu.Lock()
	cur := r.cur
	cancel := r.cancel
	if cur == nil || s.open != r {
		r.mu.Unlock()
		return nil
	}
	r.fetching = true
	r.firstPage = nil
	r.mu.Unlock()
	s.runMu.Lock()
	s.cancelled = false
	s.runMu.Unlock()
	s.setRunning(s.conn, cancel)
	eof, _, err := r.fill(target, time.Now(), progress)
	s.setRunning(nil, nil)
	r.mu.Lock()
	r.fetching = false
	r.mu.Unlock()
	if s.conn != nil {
		s.touchLocked()
	}
	var e *Error
	switch {
	case err != nil:
		s.ds.mu.Lock()
		secret := s.ds.secret
		s.ds.mu.Unlock()
		e = classifyError(err, secret)
		s.open = nil
		r.mu.Lock()
		r.cur, r.cancel, r.truncated = nil, nil, true
		r.mu.Unlock()
		_ = cur.close(true)
		cancel()
		if s.conn != nil && s.conn.broken() {
			s.conn.close()
			s.conn = nil
			s.state = "failed"
			e.Kind = "connectionLost"
			e.Message = defaultMessages["connectionLost"]
		}
	case eof:
		s.open = nil
		r.mu.Lock()
		r.cur, r.cancel, r.complete = nil, nil, true
		r.mu.Unlock()
		_ = cur.close(false)
		cancel()
	}
	return e
}

func (r *result) fetchAll() FetchAllResult {
	last := time.Time{}
	progress := func(n int64) {
		now := time.Now()
		if now.Sub(last) < 250*time.Millisecond {
			return
		}
		last = now
		emit(Event{Event: "fetchProgress", ConsoleID: r.sess.id, DataSource: r.sess.ds.id, ResultID: r.id, RowsFetched: n})
	}
	e := r.readMore(math.MaxInt64, progress)
	r.mu.Lock()
	complete := r.complete
	r.mu.Unlock()
	return FetchAllResult{RowsFetched: r.sp.rowCount(), Complete: complete, SpoolDiskBytes: r.sp.diskBytes(), Error: e}
}

type sortKeyValues struct {
	null []bool
	num  []float64
	offs []uint32
	text []byte
	kind uint8
}

func (v *sortKeyValues) str(i int64) []byte { return v.text[v.offs[i]:v.offs[i+1]] }

func numericKind(k uint8) bool { return k == KindInt || k == KindFloat || k == KindDecimal }

func (r *result) sort(keys []SortKey) SortResult {
	r.mu.Lock()
	complete := r.complete
	r.mu.Unlock()
	for _, k := range keys {
		if k.Column < 0 || k.Column >= len(r.kinds) {
			return SortResult{Error: newError("internal", "GoLens could not sort by that column.")}
		}
	}
	if len(keys) == 0 {
		r.mu.Lock()
		r.perm = nil
		r.version++
		r.firstPage = nil
		v := r.version
		r.mu.Unlock()
		return SortResult{Version: v, SortedRows: r.sp.rowCount(), Complete: complete}
	}
	total := r.sp.rowCount()
	vals := make([]sortKeyValues, len(keys))
	for i, k := range keys {
		vals[i] = sortKeyValues{null: make([]bool, total), offs: make([]uint32, 1, total+1), kind: r.kinds[k.Column]}
		if numericKind(vals[i].kind) {
			vals[i].num = make([]float64, total)
		}
	}
	tooLarge := false
	err := r.sp.eachChunk(func(start int64, rows int, cols []colChunk) {
		for i, k := range keys {
			cc := cols[k.Column]
			kv := &vals[i]
			for j := 0; j < rows && start+int64(j) < total && !tooLarge; j++ {
				idx := start + int64(j)
				v, null := cc.cell(j)
				switch {
				case null:
					kv.null[idx] = true
				case kv.num != nil:
					if f, err := strconv.ParseFloat(string(v), 64); err == nil {
						kv.num[idx] = f
					} else {
						kv.num[idx] = math.NaN()
						kv.text = append(kv.text, v...)
					}
				default:
					kv.text = append(kv.text, v...)
				}
				tooLarge = len(kv.text) > math.MaxUint32
				kv.offs = append(kv.offs, uint32(len(kv.text)))
			}
		}
	})
	if err != nil || tooLarge {
		return SortResult{Error: newError("internal", "GoLens could not sort the result.")}
	}
	perm := make([]int64, total)
	for i := range perm {
		perm[i] = int64(i)
	}
	slices.SortStableFunc(perm, func(x, y int64) int {
		for i, k := range keys {
			if c := compareKey(&vals[i], x, y); c != 0 {
				if k.Descending {
					return -c
				}
				return c
			}
		}
		return 0
	})
	r.mu.Lock()
	r.perm = perm
	r.version++
	r.firstPage = nil
	v := r.version
	r.mu.Unlock()
	return SortResult{Version: v, SortedRows: total, Complete: complete}
}

func compareKey(v *sortKeyValues, x, y int64) int {
	nx, ny := v.null[x], v.null[y]
	switch {
	case nx && ny:
		return 0
	case nx:
		return 1
	case ny:
		return -1
	}
	if v.num != nil {
		a, b := v.num[x], v.num[y]
		an, bn := math.IsNaN(a), math.IsNaN(b)
		switch {
		case !an && !bn:
			switch {
			case a < b:
				return -1
			case a > b:
				return 1
			}
			return 0
		case !an:
			return -1
		case !bn:
			return 1
		}
	}
	return bytes.Compare(v.str(x), v.str(y))
}

func (r *result) cell(row int64, col int, maxBytes int) CellValue {
	if col < 0 || col >= len(r.kinds) {
		return CellValue{Error: newError("internal", "That cell is outside the result.")}
	}
	rows, _, _ := r.viewRows(row, 1)
	if len(rows) == 0 {
		return CellValue{Error: newError("internal", "That cell is outside the loaded rows.")}
	}
	refs, err := r.sp.refs(rows)
	if err != nil {
		return CellValue{Error: newError("internal", "GoLens could not read that cell.")}
	}
	kind := r.kinds[col]
	out := CellValue{Kind: KindName(kind), Encoding: "utf8"}
	v, null := refs[0].cols[col].cell(refs[0].idx)
	if null {
		out.IsNull = true
		return out
	}
	if maxBytes <= 0 {
		maxBytes = 1 << 20
	}
	out.ByteCount = int64(len(v))
	if kind == KindBinary {
		out.Encoding = "hex"
		n := len(v)
		if n*2 > maxBytes {
			n = maxBytes / 2
			out.Truncated = true
		}
		out.Text = hex.EncodeToString(v[:n])
		return out
	}
	if len(v) > maxBytes {
		end := maxBytes
		for end > 0 && !utf8.RuneStart(v[end]) {
			end--
		}
		v = v[:end]
		out.Truncated = true
	}
	out.Text = string(v)
	return out
}

func lookupResult(id string) *result {
	reg.mu.Lock()
	defer reg.mu.Unlock()
	reg.init()
	return reg.results[id]
}

func FetchPage(id string, first int64, maxRows int) ([]byte, bool) {
	r := lookupResult(id)
	if r == nil {
		return nil, false
	}
	return r.page(first, maxRows), true
}

func FetchAll(id string) FetchAllResult {
	r := lookupResult(id)
	if r == nil {
		return FetchAllResult{Error: newError("internal", "That result is no longer available. Run the statement again.")}
	}
	return r.fetchAll()
}

func SortResultRows(id string, keys []SortKey) SortResult {
	r := lookupResult(id)
	if r == nil {
		return SortResult{Error: newError("internal", "That result is no longer available. Run the statement again.")}
	}
	return r.sort(keys)
}

func Cell(id string, row int64, col, maxBytes int) CellValue {
	r := lookupResult(id)
	if r == nil {
		return CellValue{Error: newError("internal", "That result is no longer available. Run the statement again.")}
	}
	return r.cell(row, col, maxBytes)
}

func CloseResult(id string) {
	reg.mu.Lock()
	reg.init()
	r := reg.results[id]
	delete(reg.results, id)
	reg.mu.Unlock()
	if r == nil {
		return
	}
	s := r.sess
	r.mu.Lock()
	fetching := r.fetching
	r.perm = nil
	r.firstPage = nil
	r.mu.Unlock()
	if fetching {
		s.interrupt()
	}
	s.mu.Lock()
	if s.open == r {
		s.abandonOpenLocked(true)
	}
	s.mu.Unlock()
	freed := r.sp.close()
	r = nil
	s = nil
	if freed {
		releaseMemory()
	}
}
