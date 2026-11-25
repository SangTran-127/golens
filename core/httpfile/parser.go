package httpfile

import (
	"strconv"
	"strings"
)

type Header struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type BodyPart struct {
	Text       string `json:"text,omitempty"`
	File       string `json:"file,omitempty"`
	Substitute bool   `json:"substitute,omitempty"`
	Line       int    `json:"line"`
}

type Request struct {
	Index       int        `json:"index"`
	Name        string     `json:"name"`
	Title       string     `json:"title"`
	Method      string     `json:"method"`
	URL         string     `json:"url"`
	HTTPVersion string     `json:"httpVersion,omitempty"`
	Headers     []Header   `json:"headers"`
	Body        []BodyPart `json:"body,omitempty"`
	Handler     string     `json:"handler,omitempty"`
	HandlerFile string     `json:"handlerFile,omitempty"`
	HandlerLine int        `json:"handlerLine,omitempty"`
	Line        int        `json:"line"`
	StartLine   int        `json:"startLine"`
	EndLine     int        `json:"endLine"`
	NoRedirect  bool       `json:"noRedirect,omitempty"`
	TimeoutSec  int        `json:"timeoutSec,omitempty"`
	IsGRPC      bool       `json:"isGRPC,omitempty"`
}

type FileVariable struct {
	Name  string `json:"name"`
	Value string `json:"value"`
	Line  int    `json:"line"`
}

type File struct {
	Requests  []Request      `json:"requests"`
	Variables []FileVariable `json:"variables"`
}

var knownMethods = map[string]bool{
	"GET": true, "POST": true, "PUT": true, "DELETE": true, "PATCH": true,
	"HEAD": true, "OPTIONS": true, "TRACE": true, "CONNECT": true, "GRPC": true,
}

func IsSeparator(line string) bool {
	return strings.HasPrefix(line, "###")
}

func isComment(trimmed string) bool {
	return strings.HasPrefix(trimmed, "#") || strings.HasPrefix(trimmed, "//")
}

func commentText(trimmed string) string {
	if strings.HasPrefix(trimmed, "//") {
		return strings.TrimSpace(trimmed[2:])
	}
	return strings.TrimSpace(strings.TrimLeft(trimmed, "#"))
}

func parseVariableLine(trimmed string) (string, string, bool) {
	if !strings.HasPrefix(trimmed, "@") {
		return "", "", false
	}
	eq := strings.Index(trimmed, "=")
	if eq < 0 {
		return "", "", false
	}
	name := strings.TrimSpace(trimmed[1:eq])
	if name == "" || strings.ContainsAny(name, " \t{}") {
		return "", "", false
	}
	return name, strings.TrimSpace(trimmed[eq+1:]), true
}

func Parse(content string) File {
	content = strings.ReplaceAll(content, "\r\n", "\n")
	lines := strings.Split(content, "\n")
	file := File{Requests: []Request{}, Variables: []FileVariable{}}

	blockStart := 0
	blockFirstLine := 1
	blockTitle := ""
	flush := func(end int) {
		if req, ok := parseBlock(lines, blockStart, end, blockTitle, &file); ok {
			req.Index = len(file.Requests)
			req.StartLine = blockFirstLine
			req.EndLine = end
			file.Requests = append(file.Requests, req)
		}
	}
	for i, line := range lines {
		if IsSeparator(line) {
			flush(i)
			blockStart = i + 1
			blockFirstLine = i + 1
			blockTitle = strings.TrimSpace(strings.TrimLeft(line, "#"))
		}
	}
	flush(len(lines))
	return file
}

func parseBlock(lines []string, start, end int, title string, file *File) (Request, bool) {
	req := Request{Headers: []Header{}}
	name := ""
	i := start
	for ; i < end; i++ {
		trimmed := strings.TrimSpace(lines[i])
		if trimmed == "" {
			continue
		}
		if isComment(trimmed) {
			text := commentText(trimmed)
			if strings.HasPrefix(text, "@") {
				applyTag(&req, &name, text[1:])
			}
			continue
		}
		if varName, value, ok := parseVariableLine(trimmed); ok {
			file.Variables = append(file.Variables, FileVariable{Name: varName, Value: value, Line: i + 1})
			continue
		}
		break
	}
	if i >= end {
		return req, false
	}

	method, url, version := parseRequestLine(strings.TrimSpace(lines[i]))
	req.Method = method
	req.URL = url
	req.HTTPVersion = version
	req.Line = i + 1
	req.IsGRPC = method == "GRPC"
	i++

	for ; i < end; i++ {
		raw := lines[i]
		if raw == "" || (raw[0] != ' ' && raw[0] != '\t') {
			break
		}
		trimmed := strings.TrimSpace(raw)
		if strings.HasPrefix(trimmed, "?") || strings.HasPrefix(trimmed, "&") || strings.HasPrefix(trimmed, "/") {
			req.URL += trimmed
			continue
		}
		break
	}

	for ; i < end; i++ {
		trimmed := strings.TrimSpace(lines[i])
		if trimmed == "" {
			i++
			break
		}
		if isComment(trimmed) {
			continue
		}
		if looksLikeBodyStart(trimmed) {
			break
		}
		colon := strings.Index(trimmed, ":")
		if colon <= 0 {
			break
		}
		req.Headers = append(req.Headers, Header{
			Name:  strings.TrimSpace(trimmed[:colon]),
			Value: strings.TrimSpace(trimmed[colon+1:]),
		})
	}

	var text []string
	textStart := 0
	flushText := func() {
		for len(text) > 0 && strings.TrimSpace(text[len(text)-1]) == "" {
			text = text[:len(text)-1]
		}
		if len(text) > 0 {
			req.Body = append(req.Body, BodyPart{Text: strings.Join(text, "\n"), Line: textStart + 1})
		}
		text = nil
	}
	for ; i < end; i++ {
		raw := lines[i]
		trimmed := strings.TrimSpace(raw)
		switch {
		case strings.HasPrefix(trimmed, ">>"), strings.HasPrefix(trimmed, "<>"):
			continue
		case strings.HasPrefix(trimmed, "> {%"):
			flushText()
			script, last := readScript(lines, i, end, strings.TrimPrefix(trimmed, "> {%"))
			req.Handler = script
			req.HandlerLine = i + 1
			i = last
			continue
		case strings.HasPrefix(trimmed, "> ") && !strings.Contains(trimmed, "{%"):
			flushText()
			req.HandlerFile = strings.TrimSpace(trimmed[2:])
			req.HandlerLine = i + 1
			continue
		case strings.HasPrefix(trimmed, "<@ "), strings.HasPrefix(trimmed, "<@\t"):
			flushText()
			req.Body = append(req.Body, BodyPart{File: strings.TrimSpace(trimmed[2:]), Substitute: true, Line: i + 1})
			continue
		case strings.HasPrefix(trimmed, "< "), strings.HasPrefix(trimmed, "<\t"):
			flushText()
			req.Body = append(req.Body, BodyPart{File: strings.TrimSpace(trimmed[1:]), Line: i + 1})
			continue
		}
		if req.Handler != "" || req.HandlerFile != "" {
			continue
		}
		if len(text) == 0 {
			if trimmed == "" {
				continue
			}
			textStart = i
		}
		text = append(text, raw)
	}
	flushText()

	if name == "" {
		name = title
	}
	req.Name = name
	switch {
	case title != "":
		req.Title = title
	case name != "":
		req.Title = name
	default:
		req.Title = req.Method + " " + req.URL
	}
	return req, true
}

func applyTag(req *Request, name *string, tag string) {
	key, value, _ := strings.Cut(tag, " ")
	if k, v, ok := strings.Cut(key, "="); ok {
		key, value = k, v
	}
	value = strings.TrimSpace(value)
	switch strings.ToLower(key) {
	case "name":
		*name = value
	case "no-redirect":
		req.NoRedirect = true
	case "timeout":
		if n, err := strconv.Atoi(strings.TrimSuffix(value, "s")); err == nil && n > 0 {
			req.TimeoutSec = n
		}
	}
}

func looksLikeBodyStart(trimmed string) bool {
	return strings.HasPrefix(trimmed, "{") || strings.HasPrefix(trimmed, "[") ||
		strings.HasPrefix(trimmed, "< ") || strings.HasPrefix(trimmed, "<@") ||
		strings.HasPrefix(trimmed, "> {%") || strings.HasPrefix(trimmed, "<?xml")
}

func readScript(lines []string, start, end int, firstRest string) (string, int) {
	if idx := strings.Index(firstRest, "%}"); idx >= 0 {
		return strings.TrimSpace(firstRest[:idx]), start
	}
	var parts []string
	if s := strings.TrimSpace(firstRest); s != "" {
		parts = append(parts, firstRest)
	}
	for j := start + 1; j < end; j++ {
		if idx := strings.Index(lines[j], "%}"); idx >= 0 {
			if before := lines[j][:idx]; strings.TrimSpace(before) != "" {
				parts = append(parts, before)
			}
			return strings.Join(parts, "\n"), j
		}
		parts = append(parts, lines[j])
	}
	return strings.Join(parts, "\n"), end - 1
}

func parseRequestLine(line string) (string, string, string) {
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return "GET", "", ""
	}
	method := "GET"
	if knownMethods[strings.ToUpper(fields[0])] {
		method = strings.ToUpper(fields[0])
		fields = fields[1:]
	}
	version := ""
	if n := len(fields); n > 0 && strings.HasPrefix(strings.ToUpper(fields[n-1]), "HTTP/") {
		version = fields[n-1]
		fields = fields[:n-1]
	}
	return method, strings.Join(fields, " "), version
}

func RequestAtLine(file File, line int) (Request, bool) {
	for _, r := range file.Requests {
		if line >= r.StartLine && line <= r.EndLine {
			return r, true
		}
	}
	return Request{}, false
}
