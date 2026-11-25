package search

import (
	"bytes"
	"context"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"golens/core/fsutil"
)

const (
	MaxFileBytes     = 1 << 20
	MaxMatches       = 2000
	MaxMatchesInFile = 100
	MaxFiles         = 100_000
	maxLineBytes     = 300
	flushInterval    = 30 * time.Millisecond
	gitFilesCacheTTL = 3 * time.Second
)

var skippedDirs = map[string]bool{
	".git": true, "vendor": true, "node_modules": true, ".build": true,
	"build": true, "third_party": true, ".agents": true, ".scannerwork": true, ".idea": true,
}

var skippedExts = map[string]bool{
	".png": true, ".jpg": true, ".jpeg": true, ".gif": true, ".tiff": true, ".bmp": true, ".pdf": true, ".zip": true,
	".tar": true, ".gz": true, ".exe": true, ".dylib": true, ".so": true, ".a": true, ".o": true, ".bin": true,
	".db": true, ".sqlite": true, ".ico": true, ".wasm": true, ".syso": true,
}

type Match struct {
	Line   int    `json:"line"`
	Column int    `json:"column"`
	Length int    `json:"length"`
	Offset int    `json:"offset"`
	Text   string `json:"text"`
}

type FileMatches struct {
	Path     string  `json:"path"`
	Relative string  `json:"relative"`
	Matches  []Match `json:"matches"`
}

type Batch struct {
	ID        int64         `json:"id"`
	Files     []FileMatches `json:"files,omitempty"`
	Done      bool          `json:"done,omitempty"`
	Total     int           `json:"total,omitempty"`
	Truncated bool          `json:"truncated,omitempty"`
	Millis    int64         `json:"millis,omitempty"`
}

var Emit = func(string) {
}

var openFile = os.Open

var (
	mu     sync.Mutex
	cancel context.CancelFunc
	nextID int64
)

func Start(root, query string) int64 {
	mu.Lock()
	if cancel != nil {
		cancel()
	}
	nextID++
	id := nextID
	ctx, c := context.WithCancel(context.Background())
	cancel = c
	mu.Unlock()
	go func() {
		Run(ctx, root, query, func(b Batch) {
			b.ID = id
			if data, err := json.Marshal(b); err == nil {
				Emit(string(data))
			}
		})
	}()
	return id
}

func Cancel() {
	mu.Lock()
	defer mu.Unlock()
	if cancel != nil {
		cancel()
		cancel = nil
	}
}

func listFiles(ctx context.Context, root string, out chan<- string) {
	listFilesWith(ctx, root, out, gitFiles)
}

func listFilesWith(ctx context.Context, root string, out chan<- string, lister func(context.Context, string) ([]string, bool)) {
	defer close(out)
	send := func(p string) bool {
		select {
		case out <- p:
			return true
		case <-ctx.Done():
			return false
		}
	}
	if files, ok := lister(ctx, root); ok {
		n := 0
		for _, rel := range files {
			if !included(rel) {
				continue
			}
			if n++; n > MaxFiles || !send(filepath.Join(root, rel)) {
				return
			}
		}
		return
	}
	n := 0
	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || ctx.Err() != nil {
			if d != nil && d.IsDir() && ctx.Err() == nil {
				return filepath.SkipDir
			}
			return ctx.Err()
		}
		if d.IsDir() {
			if path != root && (strings.HasPrefix(d.Name(), ".") || skippedDirs[d.Name()]) {
				return filepath.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() || strings.HasPrefix(d.Name(), ".") || skippedExts[strings.ToLower(filepath.Ext(d.Name()))] {
			return nil
		}
		if n++; n > MaxFiles || !send(path) {
			return filepath.SkipAll
		}
		return nil
	})
}

func gitFiles(ctx context.Context, root string) ([]string, bool) {
	out, exitCode, err := fsutil.RunGit(ctx, root, root, nil, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
	if err != nil || exitCode != 0 {
		return nil, false
	}
	var files []string
	for f := range bytes.SplitSeq(out, []byte{0}) {
		if len(f) > 0 {
			files = append(files, string(f))
		}
	}
	return files, true
}

type gitFilesEntry struct {
	files []string
	at    time.Time
}

var (
	gitFilesCacheMu sync.Mutex
	gitFilesCache   = map[string]gitFilesEntry{}
)

func cachedGitFiles(ctx context.Context, root string) ([]string, bool) {
	gitFilesCacheMu.Lock()
	if e, ok := gitFilesCache[root]; ok && time.Since(e.at) < gitFilesCacheTTL {
		gitFilesCacheMu.Unlock()
		return e.files, true
	}
	gitFilesCacheMu.Unlock()
	files, ok := gitFiles(ctx, root)
	if !ok {
		return nil, false
	}
	gitFilesCacheMu.Lock()
	now := time.Now()
	for k, e := range gitFilesCache {
		if now.Sub(e.at) >= gitFilesCacheTTL {
			delete(gitFilesCache, k)
		}
	}
	gitFilesCache[root] = gitFilesEntry{files: files, at: now}
	gitFilesCacheMu.Unlock()
	return files, true
}

func included(rel string) bool {
	parts := strings.Split(filepath.ToSlash(rel), "/")
	for _, p := range parts[:len(parts)-1] {
		if skippedDirs[p] {
			return false
		}
	}
	return !skippedExts[strings.ToLower(filepath.Ext(rel))]
}

func lowerASCII(dst, src []byte) []byte {
	dst = append(dst[:0], src...)
	for i, c := range dst {
		if c >= 'A' && c <= 'Z' {
			dst[i] = c + 32
		}
	}
	return dst
}

func utf16Len(b []byte) int {
	n := 0
	for len(b) > 0 {
		if b[0] < utf8.RuneSelf {
			n++
			b = b[1:]
			continue
		}
		r, size := utf8.DecodeRune(b)
		if r >= 0x10000 {
			n += 2
		} else {
			n++
		}
		b = b[size:]
	}
	return n
}

func scanFile(content, lowered, needle []byte, limit int) []Match {
	if len(content) == 0 || bytes.IndexByte(content[:min(len(content), 8000)], 0) >= 0 {
		return nil
	}
	hay := content
	if lowered != nil {
		hay = lowered
	}
	var matches []Match
	line, lineStart, lineStart16, pos := 1, 0, 0, 0
	for len(matches) < limit {
		i := bytes.Index(hay[pos:], needle)
		if i < 0 {
			break
		}
		at := pos + i
		for {
			nl := bytes.IndexByte(content[lineStart:at], '\n')
			if nl < 0 {
				break
			}
			lineStart16 += utf16Len(content[lineStart : lineStart+nl+1])
			lineStart += nl + 1
			line++
		}
		end := bytes.IndexByte(content[at:], '\n')
		if end < 0 {
			end = len(content)
		} else {
			end += at
		}
		text := bytes.TrimRight(content[lineStart:end], "\r")
		if len(text) > maxLineBytes {
			text = text[:maxLineBytes]
			for len(text) > 0 && !utf8.Valid(text) {
				text = text[:len(text)-1]
			}
		}
		col := utf16Len(content[lineStart:at])
		matches = append(matches, Match{Line: line, Column: col, Length: utf16Len(content[at : at+len(needle)]), Offset: lineStart16 + col, Text: string(text)})
		pos = at + len(needle)
		if pos >= len(content) {
			break
		}
	}
	return matches
}

func Run(ctx context.Context, root, query string, emit func(Batch)) {
	started := time.Now()
	needle := []byte(query)
	fold := bytes.ContainsFunc(needle, func(r rune) bool { return r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' })
	if fold {
		needle = lowerASCII(nil, needle)
	}
	if len(needle) == 0 {
		emit(Batch{Done: true})
		return
	}
	workCtx, stopWork := context.WithCancel(ctx)
	defer stopWork()
	paths := make(chan string, 256)
	results := make(chan FileMatches, 64)
	go listFilesWith(workCtx, root, paths, cachedGitFiles)
	var wg sync.WaitGroup
	workers := min(8, max(2, runtime.NumCPU()))
	for range workers {
		wg.Go(func() {
			var buf, low []byte
			for path := range paths {
				if workCtx.Err() != nil {
					continue
				}
				f, err := openFile(path)
				if err != nil {
					continue
				}
				fi, err := f.Stat()
				if err != nil || !fi.Mode().IsRegular() || fi.Size() > MaxFileBytes {
					_ = f.Close()
					continue
				}
				buf = buf[:0]
				if cap(buf) < int(fi.Size())+1 {
					buf = make([]byte, 0, int(fi.Size())+512)
				}
				n, _ := f.Read(buf[:cap(buf)])
				for n < int(fi.Size()) {
					m, err := f.Read(buf[n:cap(buf)])
					n += m
					if err != nil || m == 0 {
						break
					}
				}
				_ = f.Close()
				content := buf[:n]
				var lowered []byte
				if fold {
					low = lowerASCII(low, content)
					lowered = low
				}
				if m := scanFile(content, lowered, needle, MaxMatchesInFile); len(m) > 0 {
					rel, err := filepath.Rel(root, path)
					if err != nil {
						rel = path
					}
					select {
					case results <- FileMatches{Path: path, Relative: rel, Matches: m}:
					case <-workCtx.Done():
					}
				}
			}
		})
	}
	go func() {
		wg.Wait()
		close(results)
	}()
	total := 0
	truncated := false
	var pending []FileMatches
	ticker := time.NewTicker(flushInterval)
	defer ticker.Stop()
	flush := func() {
		if len(pending) > 0 && ctx.Err() == nil {
			emit(Batch{Files: pending})
		}
		pending = nil
	}
	for {
		select {
		case fm, ok := <-results:
			if !ok {
				flush()
				if ctx.Err() == nil {
					emit(Batch{Done: true, Total: total, Truncated: truncated, Millis: time.Since(started).Milliseconds()})
				}
				return
			}
			if total >= MaxMatches {
				truncated = true
				stopWork()
				continue
			}
			if room := MaxMatches - total; len(fm.Matches) > room {
				fm.Matches = fm.Matches[:room]
				truncated = true
				stopWork()
			}
			total += len(fm.Matches)
			pending = append(pending, fm)
		case <-ticker.C:
			flush()
		}
	}
}
