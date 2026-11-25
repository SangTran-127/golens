package lsp

import (
	"bytes"
	"cmp"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"unsafe"

	"golens/core/bridge"
)

const (
	MaxLSPDocumentBytes     = 10 << 20
	editHistory             = 32
	defaultMaxGoplsOpenDocs = 20
)

type ChangeStatus int

const (
	ChangeApplied ChangeStatus = iota
	ChangeUnknownDocument
	ChangeDesync
)

type editMark struct {
	version int32
	start   int
}

type document struct {
	path     string
	uri      string
	lang     string
	buf      *FileBuffer
	version  int32
	sent     bool
	dirty    bool
	lastUsed uint64
	marks    [editHistory]editMark
	nmarks   int
}

const maxVisibleDocuments = 4

type docStore struct {
	mu      sync.Mutex
	sendMu  sync.Mutex
	docs    map[string]*document
	srv     *server
	visible []string
	clock   uint64
	maxOpen int
}

var docs = &docStore{docs: make(map[string]*document)}

func languageID(path string) string {
	switch base := filepath.Base(path); {
	case strings.HasSuffix(base, ".go"):
		return "go"
	case base == "go.mod":
		return "go.mod"
	case base == "go.sum":
		return "go.sum"
	case base == "go.work":
		return "go.work"
	}
	return ""
}

func (d *document) syncable() bool {
	return d.lang != "" && len(d.buf.Content) <= MaxLSPDocumentBytes
}

func (d *document) mark(start int) {
	d.marks[d.nmarks%editHistory] = editMark{d.version, start}
	d.nmarks++
}

func (d *document) editedBefore(version int32, offset int) bool {
	n := min(d.nmarks, editHistory)
	if d.version-version > int32(n) {
		return true
	}
	for i := 0; i < n; i++ {
		m := d.marks[(d.nmarks-1-i)%editHistory]
		if m.version > version && m.start < offset {
			return true
		}
	}
	return false
}

type textDocumentItem struct {
	URI        string `json:"uri"`
	LanguageID string `json:"languageId"`
	Version    int32  `json:"version"`
	Text       string `json:"text"`
}

type versionedDoc struct {
	URI     string `json:"uri"`
	Version int32  `json:"version"`
}

type docID struct {
	URI string `json:"uri"`
}

type contentChange struct {
	Range *lspRange `json:"range,omitempty"`
	Text  string    `json:"text"`
}

func bytesView(b []byte) string {
	if len(b) == 0 {
		return ""
	}
	return unsafe.String(&b[0], len(b))
}

func (s *docStore) sendOpenLocked(d *document) {
	if s.srv == nil || !d.syncable() {
		d.sent = false
		return
	}
	d.sent = s.srv.c.notify("textDocument/didOpen", map[string]any{
		"textDocument": textDocumentItem{d.uri, d.lang, d.version, bytesView(d.buf.Content)},
	}) == nil
}

func (s *docStore) sendCloseLocked(d *document) {
	if s.srv != nil && d.sent {
		_ = s.srv.c.notify("textDocument/didClose", map[string]any{"textDocument": docID{d.uri}})
	}
	d.sent = false
}

func (s *docStore) sendChangeLocked(d *document, changes []contentChange) {
	if s.srv == nil || !d.sent {
		if s.srv != nil && d.syncable() {
			s.sendOpenLocked(d)
		}
		return
	}
	if !d.syncable() {
		s.sendCloseLocked(d)
		return
	}
	_ = s.srv.c.sendChange(d.uri, d.version, changes)
}

type fullTextSend struct {
	srv     *server
	doc     *document
	open    bool
	close   bool
	uri     string
	lang    string
	version int32
	text    string
}

func (s *docStore) planFullTextLocked(d *document, text string) fullTextSend {
	plan := fullTextSend{srv: s.srv, doc: d, uri: d.uri, lang: d.lang, version: d.version, text: text}
	if s.srv == nil {
		d.sent = false
		return fullTextSend{}
	}
	if !d.sent {
		if !d.syncable() {
			return fullTextSend{}
		}
		d.sent = true
		plan.open = true
		return plan
	}
	if !d.syncable() {
		d.sent = false
		plan.close = true
		return plan
	}
	return plan
}

func (s *docStore) sendFullTextUnlocked(path string, plan fullTextSend) {
	if plan.srv == nil {
		s.sendMu.Unlock()
		return
	}
	var err error
	switch {
	case plan.open:
		err = plan.srv.c.notify("textDocument/didOpen", map[string]any{
			"textDocument": textDocumentItem{plan.uri, plan.lang, plan.version, plan.text},
		})
	case plan.close:
		_ = plan.srv.c.notify("textDocument/didClose", map[string]any{"textDocument": docID{plan.uri}})
	default:
		_ = plan.srv.c.sendChange(plan.uri, plan.version, []contentChange{{Text: plan.text}})
	}
	s.sendMu.Unlock()
	if err != nil {
		s.mu.Lock()
		if s.docs[path] == plan.doc && s.srv == plan.srv {
			plan.doc.sent = false
		}
		s.mu.Unlock()
	}
}

func (s *docStore) nextTickLocked() uint64 {
	s.clock++
	return s.clock
}

func (s *docStore) effectiveMaxOpenLocked() int {
	if s.maxOpen > 0 {
		return s.maxOpen
	}
	if raw := strings.TrimSpace(os.Getenv("GOLENS_MAX_GOPLS_OPEN_DOCS")); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n > 0 {
			return n
		}
	}
	return defaultMaxGoplsOpenDocs
}

func (s *docStore) isVisibleLocked(path string) bool {
	for _, p := range s.visible {
		if p == path {
			return true
		}
	}
	return false
}

func (s *docStore) evictLocked(keep *document) {
	if s.srv == nil {
		return
	}
	limit := s.effectiveMaxOpenLocked()
	sentCount := 0
	for _, d := range s.docs {
		if d.sent {
			sentCount++
		}
	}
	if sentCount <= limit {
		return
	}
	cands := make([]*document, 0, len(s.docs))
	for _, cand := range s.docs {
		if cand.sent && !cand.dirty && !s.isVisibleLocked(cand.path) && cand != keep {
			cands = append(cands, cand)
		}
	}
	slices.SortFunc(cands, func(a, b *document) int {
		return cmp.Or(cmp.Compare(a.lastUsed, b.lastUsed), cmp.Compare(a.path, b.path))
	})
	for _, cand := range cands {
		if sentCount <= limit {
			break
		}
		s.sendCloseLocked(cand)
		sentCount--
	}
}

func (s *docStore) Open(path string, content []byte) {
	s.mu.Lock()
	d, ok := s.docs[path]
	if ok {
		d.buf = NewFileBuffer(content)
		d.version++
		d.mark(0)
	} else {
		d = &document{path: path, uri: pathToURI(path), lang: languageID(path), buf: NewFileBuffer(content), version: 1}
		s.docs[path] = d
	}
	d.dirty = false
	d.lastUsed = s.nextTickLocked()
	plan := s.planFullTextLocked(d, bytesView(content))
	s.sendMu.Lock()
	s.mu.Unlock()
	s.sendFullTextUnlocked(path, plan)
	if plan.srv != nil {
		s.mu.Lock()
		s.sendMu.Lock()
		if s.docs[path] == d && d.sent {
			s.evictLocked(d)
		}
		s.sendMu.Unlock()
		s.mu.Unlock()
	}
}

func (s *docStore) Change(path string, start, end int, repl []byte, expectedLen int) ChangeStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.docs[path]
	if !ok {
		return ChangeUnknownDocument
	}
	if expectedLen >= 0 && len(d.buf.Content) != expectedLen {
		return ChangeDesync
	}
	sl, sc := d.buf.Position(start)
	el, ec := d.buf.Position(end)
	if err := d.buf.Splice(start, end, repl); err != nil {
		return ChangeDesync
	}
	d.version++
	d.dirty = true
	d.lastUsed = s.nextTickLocked()
	d.mark(start)
	wasSent := d.sent
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	if s.srv != nil && d.sent && s.srv.caps.SyncKind == 2 && d.syncable() {
		s.sendChangeLocked(d, []contentChange{{Range: &lspRange{lspPos{sl, sc}, lspPos{el, ec}}, Text: bytesView(repl)}})
	} else {
		s.sendChangeLocked(d, []contentChange{{Text: bytesView(d.buf.Content)}})
	}
	if !wasSent && d.sent {
		s.evictLocked(d)
	}
	return ChangeApplied
}

func (s *docStore) Replace(path string, content []byte) ChangeStatus {
	s.mu.Lock()
	d, ok := s.docs[path]
	if !ok {
		s.mu.Unlock()
		return ChangeUnknownDocument
	}
	d.buf = NewFileBuffer(content)
	d.version++
	d.dirty = true
	d.lastUsed = s.nextTickLocked()
	d.mark(0)
	wasSent := d.sent
	plan := s.planFullTextLocked(d, bytesView(content))
	s.sendMu.Lock()
	s.mu.Unlock()
	s.sendFullTextUnlocked(path, plan)
	if !wasSent && plan.open {
		s.mu.Lock()
		s.sendMu.Lock()
		if s.docs[path] == d && d.sent {
			s.evictLocked(d)
		}
		s.sendMu.Unlock()
		s.mu.Unlock()
	}
	return ChangeApplied
}

func (s *docStore) MarkSaved(path string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.docs[path]
	if !ok {
		return
	}
	d.dirty = false
	d.lastUsed = s.nextTickLocked()
	if s.srv == nil {
		return
	}
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	s.evictLocked(nil)
}

func (s *docStore) ensureOpen(path string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.docs[path]
	if !ok || s.srv == nil || !d.syncable() {
		return
	}
	d.lastUsed = s.nextTickLocked()
	if d.sent {
		return
	}
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	s.sendOpenLocked(d)
	if d.sent {
		s.evictLocked(d)
	}
}

func (s *docStore) Close(path string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	if d, ok := s.docs[path]; ok {
		s.sendCloseLocked(d)
		delete(s.docs, path)
	}
}

func (s *docStore) CloseAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	for p, d := range s.docs {
		s.sendCloseLocked(d)
		delete(s.docs, p)
	}
}

func (s *docStore) attach(srv *server) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	s.srv = srv
	for _, d := range s.docs {
		d.sent = false
	}
	if srv == nil {
		return
	}
	var mustOpen, clean []*document
	for _, d := range s.docs {
		if !d.syncable() {
			continue
		}
		if d.dirty || s.isVisibleLocked(d.path) {
			mustOpen = append(mustOpen, d)
		} else {
			clean = append(clean, d)
		}
	}
	slices.SortFunc(mustOpen, func(a, b *document) int {
		return cmp.Or(cmp.Compare(a.lastUsed, b.lastUsed), cmp.Compare(a.path, b.path))
	})
	slices.SortFunc(clean, func(a, b *document) int {
		return cmp.Or(cmp.Compare(b.lastUsed, a.lastUsed), cmp.Compare(a.path, b.path))
	})
	opened := 0
	for _, d := range mustOpen {
		s.sendOpenLocked(d)
		if d.sent {
			opened++
		}
	}
	limit := s.effectiveMaxOpenLocked()
	for _, d := range clean {
		if opened >= limit {
			break
		}
		s.sendOpenLocked(d)
		if d.sent {
			opened++
		}
	}
}

func (s *docStore) detach(srv *server) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.srv != srv {
		return
	}
	s.srv = nil
	for _, d := range s.docs {
		d.sent = false
	}
}

type docSnapshot struct {
	srv     *server
	uri     string
	version int32
	line    int
	col     int
}

func (s *docStore) snapshot(path string, offset int) (docSnapshot, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.docs[path]
	if !ok || s.srv == nil || !d.syncable() {
		return docSnapshot{}, false
	}
	d.lastUsed = s.nextTickLocked()
	if !d.sent {
		s.sendMu.Lock()
		s.sendOpenLocked(d)
		if d.sent {
			s.evictLocked(d)
		}
		s.sendMu.Unlock()
		if !d.sent {
			return docSnapshot{}, false
		}
	}
	snap := docSnapshot{srv: s.srv, uri: d.uri, version: d.version}
	if offset >= 0 {
		snap.line, snap.col = d.buf.Position(offset)
	}
	return snap, true
}

func (s *docStore) setVisible(paths []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.visible = append(s.visible[:0], paths[:min(len(paths), maxVisibleDocuments)]...)
	for _, p := range s.visible {
		if d, ok := s.docs[p]; ok {
			d.lastUsed = s.nextTickLocked()
		}
	}
	if s.srv == nil {
		return
	}
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	for _, p := range s.visible {
		if d, ok := s.docs[p]; ok && !d.sent && d.syncable() {
			s.sendOpenLocked(d)
		}
	}
	s.evictLocked(nil)
}

func (s *docStore) isVisible(path string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.isVisibleLocked(path)
}

func SetVisibleDocuments(paths []string) { docs.setVisible(paths) }

func (s *docStore) withDoc(path string, fn func(d *document)) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.docs[path]
	if ok {
		fn(d)
	}
	return ok
}

func (s *docStore) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.docs)
}

func OpenDocument(path string, content []byte) { docs.Open(path, content) }

func ChangeDocument(path string, start, end int, repl []byte, expectedLen int) ChangeStatus {
	st := docs.Change(path, start, end, repl, expectedLen)
	if st == ChangeDesync {
		bridge.Debug("document out of sync, requesting full resync: " + path)
	}
	return st
}

func ReplaceDocument(path string, content []byte) ChangeStatus { return docs.Replace(path, content) }

func CloseDocument(path string) { docs.Close(path) }

func MarkDocumentSaved(path string) { docs.MarkSaved(path) }

func SyncSavedIfClean(path string) {
	var wantVer int32
	var check bool
	docs.withDoc(path, func(d *document) {
		if d.dirty {
			wantVer = d.version
			check = true
		}
	})
	if !check {
		return
	}
	disk, err := os.ReadFile(path)
	if err != nil {
		return
	}
	docs.mu.Lock()
	defer docs.mu.Unlock()
	d, ok := docs.docs[path]
	if !ok || !d.dirty || d.version != wantVer || !bytes.Equal(d.buf.Content, disk) {
		return
	}
	d.dirty = false
	d.lastUsed = docs.nextTickLocked()
	if docs.srv == nil {
		return
	}
	docs.sendMu.Lock()
	defer docs.sendMu.Unlock()
	docs.evictLocked(nil)
}

func DocumentContent(path string) ([]byte, error) {
	if content, ok := OpenDocumentContent(path); ok {
		return content, nil
	}
	return os.ReadFile(path)
}

func OpenDocumentContent(path string) ([]byte, bool) {
	var content []byte
	ok := docs.withDoc(path, func(d *document) { content = append([]byte(nil), d.buf.Content...) })
	return content, ok
}

func OpenDocumentPaths() []string {
	docs.mu.Lock()
	defer docs.mu.Unlock()
	paths := make([]string, 0, len(docs.docs))
	for p := range docs.docs {
		paths = append(paths, p)
	}
	return paths
}
