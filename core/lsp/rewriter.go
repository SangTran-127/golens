package lsp

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/url"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"

	"golens/core/vmexec"
)

type URITranslator struct {
	HostWorkspaceRoot  string
	GuestWorkspaceRoot string
	HostModCache       string
	GuestModCache      string
	HostGoroot         string
	GuestGoroot        string

	roots []rootMap
}

type rootMap struct {
	host      string
	guest     string
	hostKey   string
	hostPaths [][]byte
	guestPath []byte
}

type TranslatorRoots struct {
	HostWorkspace  string
	GuestWorkspace string
	HostModCache   string
	HostGoroot     string
}

func NewURITranslator(workspaceRoot string) *URITranslator {
	share := vmexec.HostShareRoots()
	clean := filepath.Clean(workspaceRoot)
	return NewURITranslatorWithRoots(TranslatorRoots{
		HostWorkspace:  clean,
		GuestWorkspace: vmexec.GuestWorkspacesRoot + "/" + vmexec.WorkspaceSlug(clean),
		HostModCache:   share.ModCache,
		HostGoroot:     share.Goroot,
	})
}

func NewURITranslatorWithRoots(r TranslatorRoots) *URITranslator {
	t := &URITranslator{
		HostWorkspaceRoot:  filepath.Clean(r.HostWorkspace),
		GuestWorkspaceRoot: r.GuestWorkspace,
		GuestModCache:      vmexec.GuestModCache,
		GuestGoroot:        vmexec.GuestGoroot,
	}
	if r.HostModCache != "" {
		t.HostModCache = filepath.Clean(r.HostModCache)
	}
	if r.HostGoroot != "" {
		t.HostGoroot = filepath.Clean(r.HostGoroot)
	}
	t.addRoot(t.HostWorkspaceRoot, t.GuestWorkspaceRoot)
	t.addRoot(t.HostModCache, t.GuestModCache)
	t.addRoot(t.HostGoroot, t.GuestGoroot)
	sort.SliceStable(t.roots, func(i, j int) bool { return len(t.roots[i].hostKey) > len(t.roots[j].hostKey) })
	return t
}

func (t *URITranslator) addRoot(host, guest string) {
	if host == "" || guest == "" || host == "/" || host == "." {
		return
	}
	r := rootMap{host: host, guest: guest, hostKey: nfc(host), guestPath: []byte(guest)}
	for _, v := range []string{host, r.hostKey, norm.NFD.String(host)} {
		if !slices.ContainsFunc(r.hostPaths, func(b []byte) bool { return string(b) == v }) {
			r.hostPaths = append(r.hostPaths, []byte(v))
		}
	}
	t.roots = append(t.roots, r)
}

func nfc(s string) string {
	for i := 0; i < len(s); i++ {
		if s[i] >= utf8.RuneSelf {
			return norm.NFC.String(s)
		}
	}
	return s
}

func underRoot(p, root string) (string, bool) {
	if !strings.HasPrefix(p, root) {
		return "", false
	}
	rest := p[len(root):]
	if rest == "" || rest[0] == '/' {
		return rest, true
	}
	return "", false
}

func (t *URITranslator) TranslateHostURI(uri string) string {
	if out, ok := t.hostURIToGuest(uri); ok {
		return out
	}
	return uri
}

func (t *URITranslator) TranslateGuestURI(uri string) string {
	if out, ok := t.guestURIToHost(uri); ok {
		return out
	}
	return uri
}

func (t *URITranslator) hostURIToGuest(uri string) (string, bool) {
	p, suffix, ok := splitFileURI(uri)
	if !ok {
		return "", false
	}
	p = nfc(p)
	for i := range t.roots {
		if rest, ok := underRoot(p, t.roots[i].hostKey); ok {
			return encodeFileURI(t.roots[i].guest+rest) + suffix, true
		}
	}
	return "", false
}

func (t *URITranslator) guestURIToHost(uri string) (string, bool) {
	p, suffix, ok := splitFileURI(uri)
	if !ok {
		return "", false
	}
	for i := range t.roots {
		if rest, ok := underRoot(p, t.roots[i].guest); ok {
			return encodeFileURI(t.roots[i].host+rest) + suffix, true
		}
	}
	return "", false
}

func splitFileURI(uri string) (path, suffix string, ok bool) {
	rest, found := strings.CutPrefix(uri, "file://")
	if !found {
		return "", "", false
	}
	if after, isLocal := strings.CutPrefix(rest, "localhost/"); isLocal {
		rest = "/" + after
	}
	if rest == "" || rest[0] != '/' {
		return "", "", false
	}
	if i := strings.IndexAny(rest, "?#"); i >= 0 {
		rest, suffix = rest[:i], rest[i:]
	}
	if strings.IndexByte(rest, '%') < 0 {
		return rest, suffix, true
	}
	decoded, err := url.PathUnescape(rest)
	if err != nil {
		return "", "", false
	}
	return decoded, suffix, true
}

func encodeFileURI(p string) string {
	for i := 0; i < len(p); i++ {
		if !goPathByte(p[i]) {
			return (&url.URL{Scheme: "file", Path: p}).String()
		}
	}
	return "file://" + p
}

func goPathByte(b byte) bool {
	switch {
	case b >= 'a' && b <= 'z', b >= 'A' && b <= 'Z', b >= '0' && b <= '9':
		return true
	}
	switch b {
	case '-', '_', '.', '~', '$', '&', '+', ',', '/', ':', ';', '=', '@':
		return true
	}
	return false
}

func unescapeJSONSlashes(body []byte) []byte {
	i := bytes.IndexByte(body, '\\')
	if i < 0 || !bytes.Contains(body[i:], []byte(`\/`)) {
		return body
	}
	out := make([]byte, 0, len(body))
	out = append(out, body[:i]...)
	for ; i < len(body); i++ {
		c := body[i]
		if c != '\\' || i+1 >= len(body) {
			out = append(out, c)
			continue
		}
		next := body[i+1]
		if next != '/' {
			out = append(out, c)
		}
		out = append(out, next)
		i++
	}
	return out
}

var fileScheme = []byte("file://")

func rewriteURIs(data []byte, stopAtParen bool, mapURI func(string) (string, bool)) []byte {
	idx := bytes.Index(data, fileScheme)
	if idx < 0 {
		return data
	}
	var out []byte
	last := 0
	for idx >= 0 {
		end := idx + len(fileScheme)
		wholeValue := idx > 0 && data[idx-1] == '"'
		for end < len(data) && !uriTerminator(data[end], stopAtParen, wholeValue) {
			end++
		}
		if mapped, ok := mapURI(string(data[idx:end])); ok {
			if out == nil {
				out = make([]byte, 0, len(data)+64)
			}
			out = append(out, data[last:idx]...)
			out = append(out, mapped...)
			last = end
		}
		next := bytes.Index(data[end:], fileScheme)
		if next < 0 {
			break
		}
		idx = end + next
	}
	if out == nil {
		return data
	}
	return append(out, data[last:]...)
}

func uriTerminator(b byte, stopAtParen, wholeValue bool) bool {
	if b == '"' || b == '\\' || b < ' ' {
		return true
	}
	if wholeValue {
		return false
	}
	switch b {
	case ' ', '<', '>', '`', '\'', '{', '}', '|', '^', 0x7f:
		return true
	case ')', ']':
		return stopAtParen
	}
	return false
}

func (t *URITranslator) RewriteHostToGuest(body []byte) []byte {
	if len(body) == 0 {
		return body
	}
	out := unescapeJSONSlashes(body)
	if bytes.Contains(out, []byte(`"textDocument/didOpen"`)) || bytes.Contains(out, []byte(`"textDocument/didChange"`)) {
		return t.rewriteDocSyncHostToGuest(out)
	}
	out = rewriteURIs(out, false, t.hostURIToGuest)
	for i := range t.roots {
		for _, hp := range t.roots[i].hostPaths {
			out = replaceBounded(out, hp, t.roots[i].guestPath)
		}
	}
	return out
}

func (t *URITranslator) rewriteDocSyncHostToGuest(body []byte) []byte {
	var env map[string]json.RawMessage
	if err := json.Unmarshal(body, &env); err != nil {
		return body
	}
	rawParams, ok := env["params"]
	if !ok {
		return body
	}

	var params map[string]json.RawMessage
	if err := json.Unmarshal(rawParams, &params); err != nil {
		return body
	}
	rawTextDoc, ok := params["textDocument"]
	if !ok {
		return body
	}

	var textDoc map[string]json.RawMessage
	if err := json.Unmarshal(rawTextDoc, &textDoc); err != nil {
		return body
	}

	rawURI, ok := textDoc["uri"]
	if !ok {
		return body
	}

	var uri string
	if err := json.Unmarshal(rawURI, &uri); err != nil {
		return body
	}

	newURI, changed := t.hostURIToGuest(uri)
	if !changed {
		return body
	}
	newURIRaw, err := json.Marshal(newURI)
	if err != nil {
		return body
	}
	textDoc["uri"] = newURIRaw

	updatedTextDoc, err := json.Marshal(textDoc)
	if err != nil {
		return body
	}
	params["textDocument"] = updatedTextDoc

	updatedParams, err := json.Marshal(params)
	if err != nil {
		return body
	}
	env["params"] = updatedParams

	newBody, err := json.Marshal(env)
	if err != nil {
		return body
	}
	return newBody
}

func (t *URITranslator) RewriteGuestToHost(body []byte) []byte {
	if len(body) == 0 {
		return body
	}
	out := rewriteURIs(body, true, t.guestURIToHost)
	for i := range t.roots {
		out = replaceBounded(out, t.roots[i].guestPath, []byte(t.roots[i].host))
	}
	return out
}

func replaceBounded(data, old, repl []byte) []byte {
	if len(old) == 0 {
		return data
	}
	idx := bytes.Index(data, old)
	if idx < 0 {
		return data
	}
	var out []byte
	last := 0
	for idx >= 0 {
		end := idx + len(old)
		if startsPath(data, idx) && (end >= len(data) || !continuesPathSegment(data[end])) {
			if out == nil {
				out = make([]byte, 0, len(data)+len(repl)-len(old))
			}
			out = append(out, data[last:idx]...)
			out = append(out, repl...)
			last = end
		}
		next := bytes.Index(data[end:], old)
		if next < 0 {
			break
		}
		idx = end + next
	}
	if out == nil {
		return data
	}
	return append(out, data[last:]...)
}

func startsPath(data []byte, idx int) bool {
	if idx == 0 {
		return true
	}
	prev := data[idx-1]
	return prev != '/' && !continuesPathSegment(prev)
}

func continuesPathSegment(b byte) bool {
	switch {
	case b >= 'a' && b <= 'z', b >= 'A' && b <= 'Z', b >= '0' && b <= '9', b >= utf8.RuneSelf:
		return true
	}
	switch b {
	case '-', '_', '.', '%', '~', '+', '@':
		return true
	}
	return false
}

func readLSPFrame(r *bufio.Reader) ([]byte, error) {
	length := -1
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line = strings.TrimSpace(line)
		if line == "" {
			break
		}
		if v, ok := strings.CutPrefix(line, "Content-Length:"); ok {
			length, _ = strconv.Atoi(strings.TrimSpace(v))
		}
	}
	if length < 0 {
		return nil, fmt.Errorf("invalid or missing Content-Length")
	}
	body := make([]byte, length)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, err
	}
	return body, nil
}

func writeLSPFrame(w io.Writer, body []byte) error {
	head := fmt.Sprintf("Content-Length: %d\r\n\r\n", len(body))
	if _, err := io.WriteString(w, head); err != nil {
		return err
	}
	_, err := w.Write(body)
	return err
}

type RewritingConn struct {
	conn       net.Conn
	translator *URITranslator

	readMu     sync.Mutex
	readBuf    bytes.Buffer
	readReader *bufio.Reader

	writeMu  sync.Mutex
	writeBuf bytes.Buffer
}

func NewRewritingConn(conn net.Conn, translator *URITranslator) *RewritingConn {
	return &RewritingConn{
		conn:       conn,
		translator: translator,
		readReader: bufio.NewReaderSize(conn, 64<<10),
	}
}

func (c *RewritingConn) Read(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()

	for c.readBuf.Len() == 0 {
		body, err := readLSPFrame(c.readReader)
		if err != nil {
			return 0, err
		}
		translated := c.translator.RewriteGuestToHost(body)
		if err := writeLSPFrame(&c.readBuf, translated); err != nil {
			return 0, err
		}
	}
	return c.readBuf.Read(p)
}

func (c *RewritingConn) Write(p []byte) (int, error) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	c.writeBuf.Write(p)

	for {
		bufBytes := c.writeBuf.Bytes()
		headerIdx := bytes.Index(bufBytes, []byte("\r\n\r\n"))
		if headerIdx < 0 {
			break
		}
		headerPart := string(bufBytes[:headerIdx])
		contentLength := -1
		for _, line := range strings.Split(headerPart, "\r\n") {
			line = strings.TrimSpace(line)
			if v, ok := strings.CutPrefix(line, "Content-Length:"); ok {
				contentLength, _ = strconv.Atoi(strings.TrimSpace(v))
			}
		}
		if contentLength < 0 {
			return 0, fmt.Errorf("malformed LSP frame header: missing Content-Length")
		}
		totalFrameLen := headerIdx + 4 + contentLength
		if len(bufBytes) < totalFrameLen {
			break
		}

		body := bufBytes[headerIdx+4 : totalFrameLen]
		translated := c.translator.RewriteHostToGuest(body)

		var outBuf bytes.Buffer
		if err := writeLSPFrame(&outBuf, translated); err != nil {
			return 0, err
		}
		if _, err := c.conn.Write(outBuf.Bytes()); err != nil {
			return 0, err
		}

		c.writeBuf.Next(totalFrameLen)
	}

	return len(p), nil
}

func (c *RewritingConn) Close() error {
	return c.conn.Close()
}

func (c *RewritingConn) LocalAddr() net.Addr {
	return c.conn.LocalAddr()
}

func (c *RewritingConn) RemoteAddr() net.Addr {
	return c.conn.RemoteAddr()
}

func (c *RewritingConn) SetDeadline(t time.Time) error {
	return c.conn.SetDeadline(t)
}

func (c *RewritingConn) SetReadDeadline(t time.Time) error {
	return c.conn.SetReadDeadline(t)
}

func (c *RewritingConn) SetWriteDeadline(t time.Time) error {
	return c.conn.SetWriteDeadline(t)
}
