package lsp

import (
	"encoding/json"
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"golens/core/bridge"
)

const (
	commandBudget     = 60 * time.Second
	applyEditWait     = 15 * time.Second
	maxPendingApplies = 16
	maxCodeLenses     = 500

	codeLensResolveConcurrency = 8
)

type lspCommand struct {
	Title     string            `json:"title"`
	Command   string            `json:"command"`
	Arguments []json.RawMessage `json:"arguments,omitempty"`
}

type uiCodeLens struct {
	Line      int               `json:"line"`
	Title     string            `json:"title"`
	Command   string            `json:"command"`
	Arguments []json.RawMessage `json:"arguments,omitempty"`
}

func errorJSON(err error) string {
	return jsonString(map[string]string{"error": err.Error()})
}

func resultJSON(raw json.RawMessage) string {
	if len(raw) == 0 {
		raw = json.RawMessage("null")
	}
	return `{"result":` + string(raw) + `}`
}

func CodeLenses(path string) string {
	snap, ok := docs.snapshot(path, -1)
	if !ok {
		return errorJSON(errServerGone)
	}
	const m = "textDocument/codeLens"
	raw, err := snap.srv.c.call(m, map[string]any{"textDocument": docID{snap.uri}}, snap.srv.budget(m), "lens:"+path)
	if err != nil {
		logRequestError("code lens", err)
		return errorJSON(err)
	}
	var lenses []struct {
		Range   lspRange        `json:"range"`
		Command *lspCommand     `json:"command"`
		Data    json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(raw, &lenses); err != nil {
		return errorJSON(err)
	}
	lenses = lenses[:min(len(lenses), maxCodeLenses)]
	cmds := make([]*lspCommand, len(lenses))
	sem := make(chan struct{}, codeLensResolveConcurrency)
	var wg sync.WaitGroup
	for i := range lenses {
		if lenses[i].Command != nil {
			cmds[i] = lenses[i].Command
			continue
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(i int) {
			defer wg.Done()
			defer func() { <-sem }()
			resolved, err := snap.srv.c.call("codeLens/resolve", lenses[i], snap.srv.budget(m), "")
			if err != nil {
				return
			}
			var r struct {
				Command *lspCommand `json:"command"`
			}
			if json.Unmarshal(resolved, &r) != nil || r.Command == nil {
				return
			}
			cmds[i] = r.Command
		}(i)
	}
	wg.Wait()
	out := make([]uiCodeLens, 0, len(lenses))
	for i, cmd := range cmds {
		if cmd == nil {
			continue
		}
		out = append(out, uiCodeLens{Line: lenses[i].Range.Start.Line, Title: cmd.Title, Command: cmd.Command, Arguments: cmd.Arguments})
	}
	return resultJSON(json.RawMessage(jsonString(out)))
}

type formAnswer struct {
	ID    string `json:"id"`
	Value any    `json:"value"`
}

type commandParams struct {
	Command     string            `json:"command"`
	Arguments   []json.RawMessage `json:"arguments,omitempty"`
	FormFields  json.RawMessage   `json:"formFields,omitempty"`
	FormAnswers []formAnswer      `json:"formAnswers,omitempty"`
}

func parseCommand(paramsJSON string) (commandParams, error) {
	var p commandParams
	if err := json.Unmarshal([]byte(paramsJSON), &p); err != nil {
		return p, err
	}
	if p.Command == "" {
		return p, errors.New("command is required")
	}
	p.FormFields = nil
	return p, nil
}

func ExecuteCommand(paramsJSON string) string {
	p, err := parseCommand(paramsJSON)
	if err != nil {
		return errorJSON(err)
	}
	srv := current()
	if srv == nil {
		return errorJSON(errServerGone)
	}
	raw, err := srv.c.call("workspace/executeCommand", p, commandBudget, "")
	if err != nil {
		return errorJSON(err)
	}
	return resultJSON(raw)
}

func ResolveCommand(paramsJSON string) string {
	p, err := parseCommand(paramsJSON)
	if err != nil {
		return errorJSON(err)
	}
	srv := current()
	if srv == nil {
		return errorJSON(errServerGone)
	}
	if !srv.caps.InteractiveCommands {
		return resultJSON(json.RawMessage(jsonString(p)))
	}
	raw, err := srv.c.call("command/resolve", p, srv.budget("command/resolve"), "")
	if err != nil {
		return errorJSON(err)
	}
	return resultJSON(raw)
}

func ListEnum(source string, config json.RawMessage, query string) string {
	srv := current()
	if srv == nil {
		return errorJSON(errServerGone)
	}
	params := map[string]any{"source": source, "query": query}
	if len(config) > 0 {
		params["config"] = config
	}
	raw, err := srv.c.call("interactive/listEnum", params, srv.budget("interactive/listEnum"), "listEnum")
	if err != nil {
		return errorJSON(err)
	}
	return resultJSON(raw)
}

func CodeActions(path string, startByte, endByte int, only []string, diagnostics json.RawMessage) string {
	snap, ok := docs.snapshot(path, -1)
	if !ok || !snap.srv.caps.CodeActions {
		return errorJSON(errServerGone)
	}
	var r lspRange
	docs.withDoc(path, func(d *document) {
		r.Start.Line, r.Start.Character = d.buf.Position(startByte)
		r.End.Line, r.End.Character = d.buf.Position(max(startByte, endByte))
	})
	if own := snap.srv.c.diagnosticsIn(snap.uri, r); len(own) > 0 {
		if b, err := json.Marshal(own); err == nil {
			diagnostics = b
		}
	}
	if len(diagnostics) == 0 {
		diagnostics = json.RawMessage("[]")
	}
	ctx := map[string]any{"diagnostics": diagnostics, "triggerKind": 1}
	if len(only) > 0 {
		ctx["only"] = only
		ctx["triggerKind"] = 2
	}
	const m = "textDocument/codeAction"
	raw, err := snap.srv.c.call(m, map[string]any{"textDocument": docID{snap.uri}, "range": r, "context": ctx}, snap.srv.budget(m), "actions:"+path)
	if err != nil {
		logRequestError("code actions", err)
		return errorJSON(err)
	}
	return resultJSON(raw)
}

func ResolveCodeAction(actionJSON string) string {
	srv := current()
	if srv == nil {
		return errorJSON(errServerGone)
	}
	if !json.Valid([]byte(actionJSON)) {
		return errorJSON(errors.New("invalid code action"))
	}
	raw, err := srv.c.call("codeAction/resolve", json.RawMessage(actionJSON), srv.budget("codeAction/resolve"), "")
	if err != nil {
		return errorJSON(err)
	}
	return resultJSON(raw)
}

type pendingApply struct {
	c  *conn
	id json.RawMessage
}

var applies struct {
	mu      sync.Mutex
	next    atomic.Int64
	pending map[int64]pendingApply
}

func (c *conn) handleApplyEdit(env *envelope) {
	var p struct {
		Label string          `json:"label"`
		Edit  json.RawMessage `json:"edit"`
	}
	if json.Unmarshal(env.Params, &p) != nil || len(p.Edit) == 0 {
		c.respond(env.ID, map[string]any{"applied": false, "failureReason": "malformed edit"})
		return
	}
	token := applies.next.Add(1)
	applies.mu.Lock()
	if applies.pending == nil {
		applies.pending = make(map[int64]pendingApply)
	}
	if len(applies.pending) >= maxPendingApplies {
		applies.mu.Unlock()
		c.respond(env.ID, map[string]any{"applied": false, "failureReason": "too many pending edits"})
		return
	}
	applies.pending[token] = pendingApply{c, append(json.RawMessage(nil), env.ID...)}
	applies.mu.Unlock()
	time.AfterFunc(applyEditWait, func() { FinishApplyEdit(token, false, "the editor did not apply the edit in time") })
	if !bridge.ApplyEdit(token, jsonString(map[string]any{"label": p.Label, "edit": p.Edit})) {
		FinishApplyEdit(token, false, "no editor attached")
	}
}

func FinishApplyEdit(token int64, applied bool, reason string) {
	applies.mu.Lock()
	p, ok := applies.pending[token]
	delete(applies.pending, token)
	applies.mu.Unlock()
	if !ok {
		return
	}
	res := map[string]any{"applied": applied}
	if !applied && reason != "" {
		res["failureReason"] = reason
	}
	p.c.respond(p.id, res)
}

func pendingApplyCount() int {
	applies.mu.Lock()
	defer applies.mu.Unlock()
	return len(applies.pending)
}
