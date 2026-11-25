package bridge

import "sync"

var (
	callbackMu    sync.RWMutex
	logFn         = func(msg string) {}
	stderrFn      = func(msg string) {}
	debugFn       = func(msg string) {}
	diagnosticsFn = func(path, payload string) {}
	lspResponseFn = func(body []byte) {}
	debugEventFn  func(event, payload string)
	applyEditFn   = func(token int64, edit string) bool { return false }
	statusFn      func(topic, payload string)
)

func swapCallback[T any](slot *T, next T) func() {
	callbackMu.Lock()
	prev := *slot
	*slot = next
	callbackMu.Unlock()
	return func() {
		callbackMu.Lock()
		*slot = prev
		callbackMu.Unlock()
	}
}

func Log(msg string) {
	callbackMu.RLock()
	fn := logFn
	callbackMu.RUnlock()
	if fn != nil {
		fn(msg)
	}
}

func Stderr(msg string) {
	callbackMu.RLock()
	fn := stderrFn
	callbackMu.RUnlock()
	if fn != nil {
		fn(msg)
	}
}

func Debug(msg string) {
	callbackMu.RLock()
	fn := debugFn
	callbackMu.RUnlock()
	if fn != nil {
		fn(msg)
	}
}

func Diagnostics(path, payload string) {
	callbackMu.RLock()
	fn := diagnosticsFn
	callbackMu.RUnlock()
	if fn != nil {
		fn(path, payload)
	}
}

func LSPResponse(body []byte) {
	callbackMu.RLock()
	fn := lspResponseFn
	callbackMu.RUnlock()
	if fn != nil {
		fn(body)
	}
}

func DebugEvent(event, payload string) {
	callbackMu.RLock()
	fn := debugEventFn
	callbackMu.RUnlock()
	if fn != nil {
		fn(event, payload)
	}
}

func ApplyEdit(token int64, edit string) bool {
	callbackMu.RLock()
	fn := applyEditFn
	callbackMu.RUnlock()
	if fn != nil {
		return fn(token, edit)
	}
	return false
}

func Status(topic, payload string) {
	callbackMu.RLock()
	fn := statusFn
	callbackMu.RUnlock()
	if fn != nil {
		fn(topic, payload)
	}
}

func HasStatus() bool {
	callbackMu.RLock()
	ok := statusFn != nil
	callbackMu.RUnlock()
	return ok
}

func HasDebugEvent() bool {
	callbackMu.RLock()
	ok := debugEventFn != nil
	callbackMu.RUnlock()
	return ok
}

func SetLog(fn func(msg string)) func()                        { return swapCallback(&logFn, fn) }
func SetStderr(fn func(msg string)) func()                     { return swapCallback(&stderrFn, fn) }
func SetDebug(fn func(msg string)) func()                      { return swapCallback(&debugFn, fn) }
func SetDiagnostics(fn func(path, payload string)) func()      { return swapCallback(&diagnosticsFn, fn) }
func SetLSPResponse(fn func(body []byte)) func()               { return swapCallback(&lspResponseFn, fn) }
func SetDebugEvent(fn func(event, payload string)) func()      { return swapCallback(&debugEventFn, fn) }
func SetApplyEdit(fn func(token int64, edit string) bool) func() { return swapCallback(&applyEditFn, fn) }
func SetStatus(fn func(topic, payload string)) func()          { return swapCallback(&statusFn, fn) }

func WrapStatus(fn func(topic, payload string, next func(topic, payload string))) func() {
	callbackMu.Lock()
	prev := statusFn
	statusFn = func(topic, payload string) {
		fn(topic, payload, prev)
	}
	callbackMu.Unlock()
	return func() {
		callbackMu.Lock()
		statusFn = prev
		callbackMu.Unlock()
	}
}
