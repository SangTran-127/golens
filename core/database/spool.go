package database

import (
	"container/list"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"runtime/debug"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
)

const (
	chunkRows     = 1024
	chunkMaxBytes = 4 << 20
)

type colChunk struct {
	nulls []byte
	offs  []uint32
	data  []byte
}

func (c *colChunk) cell(i int) ([]byte, bool) {
	if c.nulls[i/8]&(1<<(i%8)) != 0 {
		return nil, true
	}
	return c.data[c.offs[i]:c.offs[i+1]], false
}

type chunk struct {
	rows   int
	cols   []colChunk
	bytes  int
	mem    int64
	onDisk bool
	off    int64
	size   int64
	elem   *list.Element
	sp     *spool
}

func newChunk(ncols int) *chunk {
	c := &chunk{cols: make([]colChunk, ncols)}
	for i := range c.cols {
		c.cols[i].offs = make([]uint32, 1, chunkRows+1)
		c.cols[i].nulls = make([]byte, 0, chunkRows/8)
	}
	return c
}

func (c *chunk) bit(col int) {
	cc := &c.cols[col]
	for len(cc.nulls) <= c.rows/8 {
		cc.nulls = append(cc.nulls, 0)
	}
}

func (c *chunk) setNull(col int) {
	c.bit(col)
	cc := &c.cols[col]
	cc.nulls[c.rows/8] |= 1 << (c.rows % 8)
	cc.offs = append(cc.offs, uint32(len(cc.data)))
}

func (c *chunk) setValue(col int, data []byte) {
	c.bit(col)
	cc := &c.cols[col]
	c.bytes += len(data) - len(cc.data)
	cc.data = data
	cc.offs = append(cc.offs, uint32(len(cc.data)))
}

func (c *chunk) endRow() { c.rows++ }

func (c *chunk) full() bool { return c.rows >= chunkRows || c.bytes >= chunkMaxBytes }

func (c *chunk) memSize() int64 {
	var n int64
	for _, cc := range c.cols {
		n += int64(cap(cc.nulls) + 4*cap(cc.offs) + cap(cc.data))
	}
	return n + 64
}

type spool struct {
	id       string
	ncols    int
	chunks   []*chunk
	starts   []int64
	rows     int64
	file     *os.File
	path     string
	fileSize int64
	wbuf     []byte
	closed   bool
}

var spoolState = struct {
	mu    sync.Mutex
	lru   list.List
	mem   int64
	disk  int64
	limit int64
	root  string
}{limit: 16 << 20}

func spoolRoot() string {
	if spoolState.root != "" {
		return spoolState.root
	}
	base, err := os.UserCacheDir()
	if err != nil {
		base = os.TempDir()
	}
	return filepath.Join(base, "GoLens", "db-spool")
}

func cleanStaleSpools() {
	root := spoolRoot()
	entries, err := os.ReadDir(root)
	if err != nil {
		return
	}
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid == os.Getpid() || processAlive(pid) {
			continue
		}
		_ = os.RemoveAll(filepath.Join(root, e.Name()))
	}
}

func processAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func newSpool(id string, ncols int) *spool {
	return &spool{id: id, ncols: ncols}
}

func (sp *spool) rowCount() int64 {
	spoolState.mu.Lock()
	defer spoolState.mu.Unlock()
	return sp.rows
}

func (sp *spool) commit(c *chunk) {
	if c.rows == 0 {
		return
	}
	spoolState.mu.Lock()
	defer spoolState.mu.Unlock()
	if sp.closed {
		return
	}
	c.sp = sp
	c.mem = c.memSize()
	sp.starts = append(sp.starts, sp.rows)
	sp.chunks = append(sp.chunks, c)
	sp.rows += int64(c.rows)
	spoolState.mem += c.mem
	c.elem = spoolState.lru.PushFront(c)
	for spoolState.mem > spoolState.limit && spoolState.lru.Len() > 0 {
		victim := spoolState.lru.Back().Value.(*chunk)
		if err := victim.sp.spill(victim); err != nil {
			break
		}
	}
}

func (sp *spool) spill(c *chunk) error {
	if sp.file == nil {
		dir := filepath.Join(spoolRoot(), strconv.Itoa(os.Getpid()))
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
		sp.path = filepath.Join(dir, sp.id)
		f, err := os.OpenFile(sp.path, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o600)
		if err != nil {
			return err
		}
		sp.file = f
	}
	buf := binary.LittleEndian.AppendUint32(sp.wbuf[:0], uint32(c.rows))
	defer func() { sp.wbuf = buf }()
	for _, cc := range c.cols {
		buf = binary.LittleEndian.AppendUint32(buf, uint32(len(cc.nulls)))
		buf = append(buf, cc.nulls...)
		buf = binary.LittleEndian.AppendUint32(buf, uint32(len(cc.offs)))
		for _, o := range cc.offs {
			buf = binary.LittleEndian.AppendUint32(buf, o)
		}
		buf = binary.LittleEndian.AppendUint32(buf, uint32(len(cc.data)))
		buf = append(buf, cc.data...)
	}
	if _, err := sp.file.WriteAt(buf, sp.fileSize); err != nil {
		return err
	}
	c.onDisk, c.off, c.size = true, sp.fileSize, int64(len(buf))
	sp.fileSize += c.size
	spoolState.disk += c.size
	spoolState.mem -= c.mem
	spoolState.lru.Remove(c.elem)
	c.elem = nil
	c.cols = nil
	return nil
}

func (sp *spool) load(c *chunk) ([]colChunk, error) {
	if !c.onDisk {
		spoolState.lru.MoveToFront(c.elem)
		return c.cols, nil
	}
	buf := make([]byte, c.size)
	if _, err := sp.file.ReadAt(buf, c.off); err != nil {
		return nil, err
	}
	cols := make([]colChunk, sp.ncols)
	at := 4
	u32 := func() int {
		v := int(binary.LittleEndian.Uint32(buf[at:]))
		at += 4
		return v
	}
	for i := range cols {
		n := u32()
		cols[i].nulls = buf[at : at+n]
		at += n
		n = u32()
		cols[i].offs = make([]uint32, n)
		for j := range cols[i].offs {
			cols[i].offs[j] = uint32(u32())
		}
		n = u32()
		cols[i].data = buf[at : at+n]
		at += n
	}
	return cols, nil
}

type rowRef struct {
	cols []colChunk
	idx  int
}

func (sp *spool) refs(rows []int64) ([]rowRef, error) {
	spoolState.mu.Lock()
	defer spoolState.mu.Unlock()
	if sp.closed {
		return nil, errors.New("result closed")
	}
	out := make([]rowRef, len(rows))
	var lastChunk = -1
	var lastCols []colChunk
	for i, r := range rows {
		ci := sort.Search(len(sp.starts), func(k int) bool { return sp.starts[k] > r }) - 1
		if ci < 0 || r >= sp.rows {
			return nil, errors.New("row out of range")
		}
		if ci != lastChunk {
			cols, err := sp.load(sp.chunks[ci])
			if err != nil {
				return nil, err
			}
			lastChunk, lastCols = ci, cols
		}
		out[i] = rowRef{cols: lastCols, idx: int(r - sp.starts[ci])}
	}
	return out, nil
}

func (sp *spool) eachChunk(fn func(start int64, rows int, cols []colChunk)) error {
	spoolState.mu.Lock()
	n := len(sp.chunks)
	spoolState.mu.Unlock()
	for i := 0; i < n; i++ {
		spoolState.mu.Lock()
		if sp.closed {
			spoolState.mu.Unlock()
			return errors.New("result closed")
		}
		c := sp.chunks[i]
		cols, err := sp.load(c)
		start := sp.starts[i]
		spoolState.mu.Unlock()
		if err != nil {
			return err
		}
		fn(start, c.rows, cols)
	}
	return nil
}

func (sp *spool) diskBytes() int64 {
	spoolState.mu.Lock()
	defer spoolState.mu.Unlock()
	return sp.fileSize
}

func (sp *spool) close() (spilled bool) {
	spoolState.mu.Lock()
	defer spoolState.mu.Unlock()
	if sp.closed {
		return false
	}
	sp.closed = true
	var freedMem int64
	for _, c := range sp.chunks {
		if c.elem != nil {
			spoolState.lru.Remove(c.elem)
			spoolState.mem -= c.mem
			freedMem += c.mem
		}
		c.cols = nil
	}
	sp.chunks = nil
	sp.wbuf = nil
	sp.starts = nil
	if sp.file != nil {
		_ = sp.file.Close()
		_ = os.Remove(sp.path)
		spoolState.disk -= sp.fileSize
		sp.file = nil
		return true
	}
	return freedMem > 0
}

var (
	releaseRequests atomic.Int64
	freeOSMemoryMu  sync.RWMutex
	freeOSMemory    = debug.FreeOSMemory
)

func swapFreeOSMemory(fn func()) func() {
	freeOSMemoryMu.Lock()
	prev := freeOSMemory
	freeOSMemory = fn
	freeOSMemoryMu.Unlock()
	return prev
}

func runFreeOSMemory() {
	freeOSMemoryMu.RLock()
	fn := freeOSMemory
	freeOSMemoryMu.RUnlock()
	fn()
}

func releaseMemory() {
	if releaseRequests.Add(1) != 1 {
		return
	}
	go func() {
		for {
			n := releaseRequests.Load()
			runFreeOSMemory()
			if releaseRequests.Add(-n) == 0 {
				return
			}
		}
	}()
}

func spoolTotals() (mem, disk int64) {
	spoolState.mu.Lock()
	defer spoolState.mu.Unlock()
	return spoolState.mem, spoolState.disk
}
