package database

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
)

const clipboardLimit = 10 << 20

type ExportOptions struct {
	IncludeHeader *bool   `json:"includeHeader,omitempty"`
	TableName     string  `json:"tableName,omitempty"`
	NullText      *string `json:"nullText,omitempty"`
	Columns       []int   `json:"columns,omitempty"`
}

type ExportRequest struct {
	ExecID    string        `json:"execId"`
	ResultID  string        `json:"resultId"`
	Format    string        `json:"format"`
	Scope     string        `json:"scope"`
	Rows      []int64       `json:"rows,omitempty"`
	Path      string        `json:"path,omitempty"`
	Clipboard bool          `json:"clipboard,omitempty"`
	Options   ExportOptions `json:"options"`
}

type ExportResult struct {
	RowsWritten  int64  `json:"rowsWritten"`
	Bytes        int64  `json:"bytes"`
	Text         string `json:"text,omitempty"`
	CursorClosed bool   `json:"cursorClosed"`
	Error        *Error `json:"error"`
}

var (
	errTooLarge       = errors.New("export larger than the clipboard limit")
	errExportCanceled = errors.New("export canceled")
)

type cappedBuffer struct {
	buf   bytes.Buffer
	limit int
	over  atomic.Bool
}

func (c *cappedBuffer) Write(p []byte) (int, error) {
	if c.buf.Len()+len(p) > c.limit {
		c.over.Store(true)
		return 0, errTooLarge
	}
	return c.buf.Write(p)
}

type countingWriter struct {
	w io.Writer
	n int64
}

func (c *countingWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += int64(n)
	return n, err
}

type exportWriter struct {
	w       *bufio.Writer
	format  string
	dialect string
	cols    []Column
	kinds   []uint8
	pick    []int
	keys    []string
	header  bool
	null    string
	table   string
	rows    int64
	scratch []byte
	capped  *cappedBuffer
}

func (x *exportWriter) halt(stop *atomic.Bool) error {
	if x.capped != nil && x.capped.over.Load() {
		return errTooLarge
	}
	if stop.Load() {
		return errExportCanceled
	}
	return nil
}

func (x *exportWriter) cellText(col int, v []byte) []byte {
	if x.kinds[col] == KindBinary {
		x.scratch = append(x.scratch[:0], '0', 'x')
		x.scratch = hex.AppendEncode(x.scratch, v)
		return x.scratch
	}
	return v
}

func csvField(w *bufio.Writer, v []byte) {
	if bytes.ContainsAny(v, ",\"\r\n") {
		w.WriteByte('"')
		w.Write(bytes.ReplaceAll(v, []byte(`"`), []byte(`""`)))
		w.WriteByte('"')
		return
	}
	w.Write(v)
}

func tsvField(w *bufio.Writer, v []byte) {
	for _, c := range v {
		switch c {
		case '\\':
			w.WriteString(`\\`)
		case '\t':
			w.WriteString(`\t`)
		case '\n':
			w.WriteString(`\n`)
		case '\r':
			w.WriteString(`\r`)
		default:
			w.WriteByte(c)
		}
	}
}

func markdownField(w *bufio.Writer, v []byte) {
	s := strings.NewReplacer("|", `\|`, "\r\n", "<br>", "\n", "<br>", "\r", "<br>").Replace(string(v))
	w.WriteString(s)
}

func isJSONNumber(v []byte) bool {
	if len(v) == 0 {
		return false
	}
	i := 0
	if v[0] == '-' {
		i++
	}
	if i >= len(v) {
		return false
	}
	if v[i] == '0' {
		i++
	} else if v[i] >= '1' && v[i] <= '9' {
		for i < len(v) && v[i] >= '0' && v[i] <= '9' {
			i++
		}
	} else {
		return false
	}
	if i < len(v) && v[i] == '.' {
		i++
		start := i
		for i < len(v) && v[i] >= '0' && v[i] <= '9' {
			i++
		}
		if i == start {
			return false
		}
	}
	if i < len(v) && (v[i] == 'e' || v[i] == 'E') {
		i++
		if i < len(v) && (v[i] == '+' || v[i] == '-') {
			i++
		}
		start := i
		for i < len(v) && v[i] >= '0' && v[i] <= '9' {
			i++
		}
		if i == start {
			return false
		}
	}
	return i == len(v)
}

func jsonString(w *bufio.Writer, s string) {
	b, _ := json.Marshal(s)
	w.Write(b)
}

func sqlLiteralFor(dialect string, kind uint8, v []byte) string {
	switch {
	case kind == KindBinary:
		if dialect == EnginePostgres {
			return `'\x` + hex.EncodeToString(v) + `'`
		}
		return "X'" + hex.EncodeToString(v) + "'"
	case numericKind(kind) && isJSONNumber(v):
		return string(v)
	case kind == KindBool && (string(v) == "true" || string(v) == "false"):
		return strings.ToUpper(string(v))
	case dialect == EngineMySQL:
		return mysqlLiteral(string(v))
	}
	return sqlLiteral(string(v))
}

func qualifiedFromText(dialect, name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		name = "my_table"
	}
	if c := name[0]; c == '"' || c == '`' || c == '[' {
		return name
	}
	parts := strings.Split(name, ".")
	for i, p := range parts {
		parts[i] = quoteName(dialect, p)
	}
	return strings.Join(parts, ".")
}

func (x *exportWriter) begin() {
	if x.format == "json" {
		seen := map[string]int{}
		for _, c := range x.pick {
			k := x.cols[c].Name
			if n := seen[k]; n > 0 {
				seen[k] = n + 1
				k += "_" + strconv.Itoa(n+1)
			} else {
				seen[k] = 1
			}
			x.keys = append(x.keys, k)
		}
		x.w.WriteString("[")
		return
	}
	if !x.header || x.format == "sql" {
		return
	}
	switch x.format {
	case "csv":
		for i, c := range x.pick {
			if i > 0 {
				x.w.WriteByte(',')
			}
			csvField(x.w, []byte(x.cols[c].Name))
		}
		x.w.WriteString("\r\n")
	case "tsv":
		for i, c := range x.pick {
			if i > 0 {
				x.w.WriteByte('\t')
			}
			tsvField(x.w, []byte(x.cols[c].Name))
		}
		x.w.WriteByte('\n')
	case "markdown":
		x.w.WriteString("|")
		for _, c := range x.pick {
			x.w.WriteByte(' ')
			markdownField(x.w, []byte(x.cols[c].Name))
			x.w.WriteString(" |")
		}
		x.w.WriteString("\n|")
		for _, c := range x.pick {
			if numericKind(x.kinds[c]) {
				x.w.WriteString(" ---: |")
			} else {
				x.w.WriteString(" --- |")
			}
		}
		x.w.WriteByte('\n')
	}
}

func (x *exportWriter) row(cell func(col int) ([]byte, bool)) {
	switch x.format {
	case "csv", "tsv":
		sep := byte(',')
		if x.format == "tsv" {
			sep = '\t'
		}
		for i, c := range x.pick {
			if i > 0 {
				x.w.WriteByte(sep)
			}
			v, null := cell(c)
			if null {
				v = []byte(x.null)
			} else {
				v = x.cellText(c, v)
			}
			if x.format == "csv" {
				csvField(x.w, v)
			} else {
				tsvField(x.w, v)
			}
		}
		if x.format == "csv" {
			x.w.WriteString("\r\n")
		} else {
			x.w.WriteByte('\n')
		}
	case "markdown":
		x.w.WriteString("|")
		for _, c := range x.pick {
			v, null := cell(c)
			x.w.WriteByte(' ')
			if null {
				markdownField(x.w, []byte(x.null))
			} else {
				markdownField(x.w, x.cellText(c, v))
			}
			x.w.WriteString(" |")
		}
		x.w.WriteByte('\n')
	case "json":
		if x.rows > 0 {
			x.w.WriteByte(',')
		}
		x.w.WriteString("\n{")
		for i, c := range x.pick {
			if i > 0 {
				x.w.WriteByte(',')
			}
			jsonString(x.w, x.keys[i])
			x.w.WriteByte(':')
			v, null := cell(c)
			k := x.kinds[c]
			switch {
			case null:
				x.w.WriteString("null")
			case numericKind(k) && isJSONNumber(v):
				x.w.Write(v)
			case k == KindBool && (string(v) == "true" || string(v) == "false"):
				x.w.Write(v)
			case k == KindJSON && json.Valid(v):
				x.w.Write(v)
			default:
				jsonString(x.w, string(x.cellText(c, v)))
			}
		}
		x.w.WriteByte('}')
	case "sql":
		x.w.WriteString("INSERT INTO " + x.table + " (")
		for i, c := range x.pick {
			if i > 0 {
				x.w.WriteString(", ")
			}
			x.w.WriteString(quoteName(x.dialect, x.cols[c].Name))
		}
		x.w.WriteString(") VALUES (")
		for i, c := range x.pick {
			if i > 0 {
				x.w.WriteString(", ")
			}
			v, null := cell(c)
			if null {
				x.w.WriteString("NULL")
			} else {
				x.w.WriteString(sqlLiteralFor(x.dialect, x.kinds[c], v))
			}
		}
		x.w.WriteString(");\n")
	}
	x.rows++
}

func (x *exportWriter) end() {
	if x.format == "json" {
		if x.rows > 0 {
			x.w.WriteByte('\n')
		}
		x.w.WriteString("]\n")
	}
}

func (x *exportWriter) chunk(cols []colChunk, rows int, stop *atomic.Bool) error {
	for i := 0; i < rows; i++ {
		x.row(func(c int) ([]byte, bool) { return cols[c].cell(i) })
		if i%256 == 255 {
			if err := x.halt(stop); err != nil {
				return err
			}
		}
	}
	return x.halt(stop)
}

func validFormat(f string) bool {
	switch f {
	case "csv", "tsv", "json", "sql", "markdown":
		return true
	}
	return false
}

func Export(req ExportRequest) (out ExportResult) {
	r := lookupResult(req.ResultID)
	if r == nil {
		out.Error = newError("internal", "That result is no longer available. Run the statement again.")
		return out
	}
	if !validFormat(req.Format) {
		out.Error = newError("internal", "Choose CSV, TSV, JSON, SQL INSERT or Markdown.")
		return out
	}
	if !req.Clipboard && !filepath.IsAbs(req.Path) {
		out.Error = newError("internal", "Choose where to save the exported file.")
		return out
	}
	r.mu.Lock()
	cols, kinds, binding := r.columns, r.kinds, r.table
	r.mu.Unlock()
	x := &exportWriter{format: req.Format, dialect: r.sess.engine(), cols: cols, kinds: kinds, header: true}
	if req.Options.IncludeHeader != nil {
		x.header = *req.Options.IncludeHeader
	}
	if req.Format == "markdown" {
		x.null = "NULL"
	}
	if req.Options.NullText != nil {
		x.null = *req.Options.NullText
	}
	switch {
	case strings.TrimSpace(req.Options.TableName) != "":
		x.table = qualifiedFromText(x.dialect, req.Options.TableName)
	case binding != nil && binding.name != "":
		x.table = qualifiedName(x.dialect, binding.schema, binding.name)
	default:
		x.table = qualifiedFromText(x.dialect, "")
	}
	for _, c := range req.Options.Columns {
		if c < 0 || c >= len(cols) {
			out.Error = newError("internal", "GoLens could not export that column.")
			return out
		}
		x.pick = append(x.pick, c)
	}
	if len(x.pick) == 0 {
		for c := range cols {
			x.pick = append(x.pick, c)
		}
	}

	var sink io.Writer
	var clip *cappedBuffer
	var tmp *os.File
	if req.Clipboard {
		clip = &cappedBuffer{limit: clipboardLimit}
		x.capped = clip
		sink = clip
	} else {
		var err error
		tmp, err = os.CreateTemp(filepath.Dir(req.Path), ".golens-export-*")
		if err != nil {
			out.Error = newError("permission", "GoLens could not write to that folder. Choose another place to save the file.")
			return out
		}
		_ = tmp.Chmod(0o644)
		sink = tmp
	}
	counter := &countingWriter{w: sink}
	x.w = bufio.NewWriterSize(counter, 256<<10)

	var stop, reading atomic.Bool
	s := r.sess
	done := reg.addOp(req.ExecID, func() {
		stop.Store(true)
		if reading.Load() {
			s.interrupt()
		}
	})
	defer done()

	x.begin()
	var err error
	switch req.Scope {
	case "selection":
		err = exportRows(r, x, req.Rows, &stop)
	case "loaded":
		err = exportLoaded(r, x, &stop)
	case "all":
		out.CursorClosed, err = exportAll(r, x, &stop, &reading)
	default:
		err = errors.New("unknown scope")
	}
	if err == nil {
		x.end()
		err = x.w.Flush()
	}
	out.RowsWritten = x.rows
	out.Bytes = counter.n
	if tmp != nil {
		cerr := tmp.Close()
		if err == nil {
			err = cerr
		}
		if err == nil {
			err = os.Rename(tmp.Name(), req.Path)
		}
		if err != nil {
			_ = os.Remove(tmp.Name())
		}
	}
	if err != nil {
		out.Text = ""
		out.Error = exportError(err, s)
		return out
	}
	if clip != nil {
		out.Text = clip.buf.String()
	}
	return out
}

func exportError(err error, s *session) *Error {
	var e *Error
	switch {
	case errors.Is(err, errTooLarge):
		return newError("tooLarge", "The result is larger than 10 MB, so GoLens did not copy it. Use Export Result to save it to a file instead.")
	case errors.Is(err, errExportCanceled):
		return errorFor("cancelled")
	case errors.As(err, &e):
		return e
	case errors.Is(err, os.ErrPermission):
		return newError("permission", "GoLens could not write to that folder. Choose another place to save the file.")
	}
	ce := s.ds.classify(err)
	if ce.Kind == "server" {
		ce.Message = "GoLens could not finish the export."
	}
	return ce
}

func (e *Error) Error() string { return e.Message }

func exportRows(r *result, x *exportWriter, rows []int64, stop *atomic.Bool) error {
	for start := 0; start < len(rows); start += chunkRows {
		end := min(len(rows), start+chunkRows)
		idx := make([]int64, 0, end-start)
		r.mu.Lock()
		perm := r.perm
		r.mu.Unlock()
		for _, v := range rows[start:end] {
			if perm != nil {
				if v < 0 || v >= int64(len(perm)) {
					return newError("internal", "A selected row is outside the result.")
				}
				v = perm[v]
			}
			idx = append(idx, v)
		}
		refs, err := r.sp.refs(idx)
		if err != nil {
			return newError("internal", "A selected row is outside the result.")
		}
		for _, ref := range refs {
			x.row(func(c int) ([]byte, bool) { return ref.cols[c].cell(ref.idx) })
		}
		if err := x.halt(stop); err != nil {
			return err
		}
	}
	return nil
}

func exportLoaded(r *result, x *exportWriter, stop *atomic.Bool) error {
	r.mu.Lock()
	perm := r.perm
	r.mu.Unlock()
	if perm != nil {
		return exportRows(r, x, permIdentity(len(perm)), stop)
	}
	var failed error
	err := r.sp.eachChunk(func(_ int64, rows int, cols []colChunk) {
		if failed == nil {
			failed = x.chunk(cols, rows, stop)
		}
	})
	if failed != nil {
		return failed
	}
	return err
}

func permIdentity(n int) []int64 {
	out := make([]int64, n)
	for i := range out {
		out[i] = int64(i)
	}
	return out
}

func exportAll(r *result, x *exportWriter, stop, reading *atomic.Bool) (bool, error) {
	r.mu.Lock()
	sorted := r.perm != nil
	complete := r.complete
	r.mu.Unlock()
	if sorted && complete {
		return false, exportLoaded(r, x, stop)
	}
	s := r.sess
	s.mu.Lock()
	defer s.mu.Unlock()
	var failed error
	err := r.sp.eachChunk(func(_ int64, rows int, cols []colChunk) {
		if failed == nil {
			failed = x.chunk(cols, rows, stop)
		}
	})
	if failed != nil {
		return false, failed
	}
	if err != nil {
		return false, err
	}
	r.mu.Lock()
	cur, cancel := r.cur, r.cancel
	if cur == nil || s.open != r {
		r.mu.Unlock()
		return false, nil
	}
	r.fetching = true
	r.firstPage = nil
	r.mu.Unlock()
	reading.Store(true)
	s.setRunning(s.conn, cancel)
	finish := func(truncated bool) {
		s.setRunning(nil, nil)
		reading.Store(false)
		s.open = nil
		r.mu.Lock()
		r.cur, r.cancel, r.fetching = nil, nil, false
		r.truncated = r.truncated || truncated
		r.mu.Unlock()
	}
	for {
		if herr := x.halt(stop); herr != nil {
			finish(true)
			s.stopCursor(cur, cancel)
			return true, herr
		}
		ch := newChunk(len(r.kinds))
		more := true
		var rerr error
		for !ch.full() && more {
			more, rerr = cur.next(ch)
			if rerr != nil {
				break
			}
		}
		if werr := x.chunk(ch.cols, ch.rows, stop); werr != nil {
			finish(true)
			s.stopCursor(cur, cancel)
			return true, werr
		}
		if rerr != nil {
			finish(true)
			_ = cur.close(true)
			cancel()
			if s.conn != nil && s.conn.broken() {
				s.conn.close()
				s.conn = nil
				s.state = "failed"
			}
			if stop.Load() {
				return true, errExportCanceled
			}
			return true, rerr
		}
		if !more {
			finish(true)
			_ = cur.close(false)
			cancel()
			if s.conn != nil {
				s.touchLocked()
			}
			return true, nil
		}
	}
}
