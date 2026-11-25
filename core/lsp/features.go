package lsp

import (
	"encoding/json"
	"errors"
	"strings"
	"time"

	"golens/core/bridge"
)

var localBudgets = map[string]time.Duration{
	"textDocument/completion":           time.Second,
	"textDocument/signatureHelp":        time.Second,
	"textDocument/semanticTokens/full":  2 * time.Second,
	"textDocument/semanticTokens/range": 2 * time.Second,
	"textDocument/formatting":           2 * time.Second,
	"textDocument/codeAction":           2 * time.Second,
	"codeAction/resolve":                5 * time.Second,
	"textDocument/rename":               5 * time.Second,
	"textDocument/codeLens":             3 * time.Second,
	"command/resolve":                   10 * time.Second,
	"interactive/listEnum":              2 * time.Second,
}

var remoteBudgets = map[string]time.Duration{
	"textDocument/completion":           3 * time.Second,
	"textDocument/signatureHelp":        3 * time.Second,
	"textDocument/semanticTokens/full":  5 * time.Second,
	"textDocument/semanticTokens/range": 5 * time.Second,
	"textDocument/formatting":           5 * time.Second,
	"textDocument/codeAction":           5 * time.Second,
	"codeAction/resolve":                10 * time.Second,
	"textDocument/rename":               20 * time.Second,
	"textDocument/codeLens":             6 * time.Second,
	"command/resolve":                   20 * time.Second,
	"interactive/listEnum":              5 * time.Second,
}

func requestBudget(remote bool, method string) time.Duration {
	table, fallback := localBudgets, 5*time.Second
	if remote {
		table, fallback = remoteBudgets, 10*time.Second
	}
	if b, ok := table[method]; ok {
		return b
	}
	return fallback
}

func (s *server) budget(method string) time.Duration {
	return requestBudget(s != nil && s.isRemote, method)
}

func current() *server {
	docs.mu.Lock()
	defer docs.mu.Unlock()
	return docs.srv
}

func logRequestError(what string, err error) {
	if err != nil && !errors.Is(err, errCancelled) && !errors.Is(err, errServerGone) {
		bridge.Debug("[LSP] " + what + ": " + err.Error())
	}
}

func SendSwiftMessage(msg []byte) bool {
	var env struct {
		Method string `json:"method"`
		Params struct {
			TextDocument struct {
				URI string `json:"uri"`
			} `json:"textDocument"`
		} `json:"params"`
	}
	var docPath string
	if json.Unmarshal(msg, &env) == nil && env.Params.TextDocument.URI != "" {
		docPath = uriToPath(env.Params.TextDocument.URI)
	}
	if docPath != "" && strings.HasPrefix(env.Method, "textDocument/") {
		switch env.Method {
		case "textDocument/didOpen", "textDocument/didChange", "textDocument/didClose", "textDocument/didSave":
		default:
			docs.ensureOpen(docPath)
		}
	}
	srv := current()
	if srv == nil {
		if docPath != "" && env.Method == "textDocument/didSave" {
			docs.MarkSaved(docPath)
		}
		return false
	}
	srv.c.flushChanges()
	reqTrace.beginSwift(msg)
	ok := srv.c.enqueue(append([]byte(nil), msg...)) == nil
	if docPath != "" && env.Method == "textDocument/didSave" {
		docs.MarkSaved(docPath)
	}
	return ok
}

func CancelSwiftRequest(id int64) {
	reqTrace.end(id, "cancelled-by-client", 0)
	if srv := current(); srv != nil {
		_ = srv.c.notify("$/cancelRequest", map[string]int64{"id": id})
	}
}

func positionParams(snap docSnapshot) map[string]any {
	return map[string]any{
		"textDocument": docID{snap.uri},
		"position":     lspPos{snap.line, snap.col},
	}
}

const maxSemanticRangeBytes = 90_000

var golensTokenCodes = map[string]int{
	"namespace": 0, "type": 1, "class": 1, "struct": 1, "interface": 1, "enum": 1, "typeParameter": 2,
	"parameter": 3, "property": 4, "enumMember": 4, "variable": 5, "function": 6, "method": 7, "macro": 8,
	"keyword": 9, "modifier": 9, "comment": 10, "string": 11, "number": 12, "regexp": 11, "operator": 13, "label": 14,
}

func SemanticTokens(path string, startByte, endByte int) ([]int32, bool) {
	if !docs.isVisible(path) {
		if traceLSP {
			bridge.Debug("[LSP] semantic tokens refused for a hidden document: " + path)
		}
		return nil, false
	}
	snap, ok := docs.snapshot(path, -1)
	if !ok {
		return nil, false
	}
	caps := snap.srv.caps
	method := "textDocument/semanticTokens/full"
	params := map[string]any{"textDocument": docID{snap.uri}}
	if caps.SemanticRange && endByte > startByte {
		endByte = min(endByte, startByte+maxSemanticRangeBytes)
		var r lspRange
		if !docs.withDoc(path, func(d *document) {
			r.Start.Line, r.Start.Character = d.buf.Position(startByte)
			r.End.Line, r.End.Character = d.buf.Position(endByte)
		}) {
			return nil, false
		}
		method = "textDocument/semanticTokens/range"
		params["range"] = r
	} else if !caps.SemanticFull {
		return nil, false
	}
	raw, err := snap.srv.c.call(method, params, snap.srv.budget(method), "tokens:"+path)
	if err != nil {
		logRequestError("semantic tokens", err)
		return nil, false
	}
	var res struct {
		Data []int `json:"data"`
	}
	if json.Unmarshal(raw, &res) != nil {
		return nil, false
	}
	codes := make([]int, len(caps.TokenTypes))
	for i, name := range caps.TokenTypes {
		if c, ok := golensTokenCodes[name]; ok {
			codes[i] = c
		} else {
			codes[i] = -1
		}
	}
	var out []int32
	fresh := false
	docs.withDoc(path, func(d *document) {
		if d.version == snap.version {
			fresh = true
			out = decodeTokens(d.buf, res.Data, codes)
		}
	})
	return out, fresh
}

func decodeTokens(buf *FileBuffer, data []int, codes []int) []int32 {
	out := make([]int32, 0, len(data)/5*3)
	line, char := 0, 0
	for i := 0; i+4 < len(data); i += 5 {
		if data[i] > 0 {
			line += data[i]
			char = data[i+1]
		} else {
			char += data[i+1]
		}
		if line >= len(buf.LineStarts) {
			break
		}
		t := data[i+3]
		if t < 0 || t >= len(codes) || codes[t] < 0 {
			continue
		}
		start := int(buf.LineStarts[line])
		end := len(buf.Content)
		if line+1 < len(buf.LineStarts) {
			end = int(buf.LineStarts[line+1]) - 1
		}
		lineBytes := buf.Content[start:end]
		s := utf16OffsetToByteOffset(lineBytes, char)
		e := utf16OffsetToByteOffset(lineBytes, char+data[i+2])
		if e > s {
			out = append(out, int32(start+s), int32(e-s), int32(codes[t]))
		}
	}
	return out
}

func SignatureHelp(path string, byteOffset int) string {
	snap, ok := docs.snapshot(path, byteOffset)
	if !ok {
		return ""
	}
	const m = "textDocument/signatureHelp"
	raw, err := snap.srv.c.call(m, positionParams(snap), snap.srv.budget(m), "signature:"+path)
	if err != nil {
		logRequestError("signature help", err)
		return ""
	}
	return `{"result":` + string(raw) + `}`
}

func Rename(path string, byteOffset int, newName string) string {
	snap, ok := docs.snapshot(path, byteOffset)
	if !ok {
		return `{"error":"language server not ready"}`
	}
	params := positionParams(snap)
	params["newName"] = newName
	const m = "textDocument/rename"
	raw, err := snap.srv.c.call(m, params, snap.srv.budget(m), "")
	if err != nil {
		b, _ := json.Marshal(map[string]string{"error": err.Error()})
		return string(b)
	}
	return `{"result":` + string(raw) + `}`
}

type textEdit struct {
	Range   lspRange `json:"range"`
	NewText string   `json:"newText"`
}

func editsResponse(version int32, edits []textEdit) string {
	if edits == nil {
		edits = []textEdit{}
	}
	b, _ := json.Marshal(map[string]any{"version": version, "edits": edits})
	return string(b)
}

func FormattingEdits(path string, tabSize int) string {
	snap, ok := docs.snapshot(path, -1)
	if !ok || !snap.srv.caps.Formatting {
		return ""
	}
	const m = "textDocument/formatting"
	raw, err := snap.srv.c.call(m, map[string]any{
		"textDocument": docID{snap.uri},
		"options":      map[string]any{"tabSize": tabSize, "insertSpaces": false},
	}, snap.srv.budget(m), "format:"+path)
	if err != nil {
		logRequestError("formatting", err)
		return ""
	}
	var edits []textEdit
	if json.Unmarshal(raw, &edits) != nil {
		return ""
	}
	return editsResponse(snap.version, edits)
}

func OrganizeImportsEdits(path string) string {
	snap, ok := docs.snapshot(path, -1)
	if !ok || !snap.srv.caps.CodeActions {
		return ""
	}
	var end lspPos
	docs.withDoc(path, func(d *document) { end.Line, end.Character = d.buf.Position(len(d.buf.Content)) })
	const m = "textDocument/codeAction"
	raw, err := snap.srv.c.call(m, map[string]any{
		"textDocument": docID{snap.uri},
		"range":        lspRange{End: end},
		"context":      map[string]any{"diagnostics": []any{}, "only": []string{"source.organizeImports"}, "triggerKind": 2},
	}, snap.srv.budget(m), "imports:"+path)
	if err != nil {
		logRequestError("organize imports", err)
		return ""
	}
	var actions []struct {
		Kind string `json:"kind"`
		Edit *struct {
			Changes         map[string][]textEdit `json:"changes"`
			DocumentChanges []struct {
				TextDocument versionedDoc `json:"textDocument"`
				Edits        []textEdit   `json:"edits"`
			} `json:"documentChanges"`
		} `json:"edit"`
	}
	if json.Unmarshal(raw, &actions) != nil {
		return ""
	}
	var edits []textEdit
	for _, a := range actions {
		if a.Kind != "source.organizeImports" || a.Edit == nil {
			continue
		}
		for _, dc := range a.Edit.DocumentChanges {
			if dc.TextDocument.URI == snap.uri {
				edits = append(edits, dc.Edits...)
			}
		}
		edits = append(edits, a.Edit.Changes[snap.uri]...)
		break
	}
	return editsResponse(snap.version, edits)
}
