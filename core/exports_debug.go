package main

import "C"

import (
	"encoding/json"
	"fmt"

	"golens/core/bridge"
	"golens/core/dap"
	"golens/core/goast"
	"golens/core/lsp"
	"golens/core/remote"
)

//export DebugStart
func DebugStart(configJson *C.char) *C.char {
	cfg := C.GoString(configJson)
	if remote.WantsRemote(cfg) {
		if err := remote.Debug(lsp.GetActiveDir(), cfg); err != nil {
			return C.CString(err.Error())
		}
		return nil
	}
	err := dap.StartDebug(cfg)
	if err != nil {
		return C.CString(err.Error())
	}
	return nil
}

//export DebugConfigurationDone
func DebugConfigurationDone() {
	bridge.Debug("DebugConfigurationDone called")
	if client := dap.GetClient(); client != nil {
		err := client.ConfigurationDone()
		if err != nil {
			bridge.Debug(fmt.Sprintf("Error sending ConfigurationDone: %v", err))
		} else {
			bridge.Debug("ConfigurationDone successfully sent")
		}
	} else {
		bridge.Debug("dap.GetClient() is nil in ConfigurationDone!")
	}
}

//export DebugStop
func DebugStop() {
	remote.CancelDebug()
	if client := dap.GetClient(); client != nil {
		client.Stop()
	}
}

//export DebugContinue
func DebugContinue(threadId C.int) {
	if client := dap.GetClient(); client != nil {
		if err := client.Continue(int(threadId)); err != nil {
			bridge.Debug(fmt.Sprintf("Error in DebugContinue: %v", err))
		}
	}
}

//export DebugPause
func DebugPause(threadId C.int) {
	if client := dap.GetClient(); client != nil {
		if err := client.Pause(int(threadId)); err != nil {
			bridge.Debug(fmt.Sprintf("Error in DebugPause: %v", err))
		}
	}
}

// Ownership: arguments are copied; breakpoints JSON is the file's own breakpoints in DebugSetBreakpoints form; returns a C.malloc'd error freed with FreeGoCString, or NULL once the program runs.
//
//export DebugRunToLine
func DebugRunToLine(cFile *C.char, line C.int, cBreakpointsJson *C.char, threadId C.int) *C.char {
	client := dap.GetClient()
	if client == nil {
		return C.CString("the debugger isn't running")
	}
	keep, err := dap.ParseBreakpoints(C.GoString(cBreakpointsJson))
	if err != nil {
		return C.CString(err.Error())
	}
	if err := client.RunToLine(C.GoString(cFile), int(line), keep, int(threadId)); err != nil {
		return C.CString(err.Error())
	}
	return nil
}

// Ownership: argument is copied; JSON is [{name,condition}]; returns a C.malloc'd JSON of DAP breakpoints in the same order, or "Error: …", freed with FreeGoCString.
//
//export DebugSetFunctionBreakpoints
func DebugSetFunctionBreakpoints(cBreakpointsJson *C.char) *C.char {
	client := dap.GetClient()
	if client == nil {
		return C.CString("Error: the debugger isn't running")
	}
	bps, err := dap.ParseFunctionBreakpoints(C.GoString(cBreakpointsJson))
	if err != nil {
		return C.CString("Error: " + err.Error())
	}
	data, err := client.SetFunctionBreakpoints(bps)
	if err != nil {
		return C.CString("Error: " + err.Error())
	}
	return C.CString(string(data))
}

//export DebugStepOver
func DebugStepOver(threadId C.int) {
	if client := dap.GetClient(); client != nil {
		if err := client.StepOver(int(threadId)); err != nil {
			bridge.Debug(fmt.Sprintf("Error in DebugStepOver: %v", err))
		}
	}
}

//export DebugStepInto
func DebugStepInto(threadId C.int) {
	if client := dap.GetClient(); client != nil {
		if err := client.StepInto(int(threadId)); err != nil {
			bridge.Debug(fmt.Sprintf("Error in DebugStepInto: %v", err))
		}
	}
}

//export DebugStepOut
func DebugStepOut(threadId C.int) {
	if client := dap.GetClient(); client != nil {
		if err := client.StepOut(int(threadId)); err != nil {
			bridge.Debug(fmt.Sprintf("Error in DebugStepOut: %v", err))
		}
	}
}

//export DebugGetThreads
func DebugGetThreads() *C.char {
	if client := dap.GetClient(); client != nil {
		data, err := client.GetThreads()
		if err == nil {
			return C.CString(string(data))
		}
	}
	return nil
}

//export DebugEvaluate
func DebugEvaluate(cExpression *C.char, frameId C.int) *C.char {
	if client := dap.GetClient(); client != nil {
		result := client.EvaluateWatch(C.GoString(cExpression), int(frameId))
		data, err := json.Marshal(result)
		if err != nil {
			return nil
		}
		return C.CString(string(data))
	}
	return nil
}

// Ownership: arguments are copied; breakpoints JSON is [{line,condition,hitCondition,logMessage}] or [line]; returns a C.malloc'd JSON of verified breakpoints freed with FreeGoCString, or NULL.
//
//export DebugSetBreakpoints
func DebugSetBreakpoints(cFile *C.char, cBreakpointsJson *C.char) *C.char {
	client := dap.GetClient()
	if client == nil {
		return nil
	}
	bps, err := dap.ParseBreakpoints(C.GoString(cBreakpointsJson))
	if err != nil {
		bridge.Debug(fmt.Sprintf("invalid breakpoints: %v", err))
		return nil
	}
	data, err := client.SetBreakpoints(C.GoString(cFile), bps)
	if err != nil {
		bridge.Debug(fmt.Sprintf("setting breakpoints failed: %v", err))
		return nil
	}
	return C.CString(string(data))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON {value,type,variablesReference} or "Error: …" freed with FreeGoCString.
//
//export DebugSetVariable
func DebugSetVariable(variablesReference C.int, cName *C.char, cValue *C.char) *C.char {
	client := dap.GetClient()
	if client == nil {
		return nil
	}
	data, err := client.SetVariable(int(variablesReference), C.GoString(cName), C.GoString(cValue))
	if err != nil {
		return C.CString("Error: " + err.Error())
	}
	return C.CString(string(data))
}

// Ownership: returns a C.malloc'd JSON exception description freed with FreeGoCString, or NULL.
//
//export DebugExceptionInfo
func DebugExceptionInfo(threadId C.int) *C.char {
	if client := dap.GetClient(); client != nil {
		if data, err := client.ExceptionInfo(int(threadId)); err == nil {
			return C.CString(string(data))
		}
	}
	return nil
}

// Ownership: returns a C.malloc'd JSON array of goroutine groups freed with FreeGoCString, or NULL.
//
//export DebugGoroutineGroups
func DebugGoroutineGroups() *C.char {
	if client := dap.GetClient(); client != nil {
		if data, err := client.GoroutineGroups(); err == nil {
			return C.CString(string(data))
		}
	}
	return nil
}

// Ownership: the project root is copied; returns a C.malloc'd plain-text goroutine dump, or "Error: …", freed with FreeGoCString.
//
//export DebugGoroutineDump
func DebugGoroutineDump(cRoot *C.char) *C.char {
	client := dap.GetClient()
	if client == nil {
		return C.CString("Error: the debugger isn't running")
	}
	dump, err := client.GoroutineDump(C.GoString(cRoot))
	if err != nil {
		return C.CString("Error: " + err.Error())
	}
	return C.CString(dump)
}

//export DebugGetStackTrace
func DebugGetStackTrace(threadId C.int) *C.char {
	if client := dap.GetClient(); client != nil {
		data, err := client.GetStackTrace(int(threadId))
		if err == nil {
			return C.CString(string(data))
		}
	}
	return nil
}

//export DebugGetScopes
func DebugGetScopes(frameId C.int) *C.char {
	if client := dap.GetClient(); client != nil {
		data, err := client.GetScopes(int(frameId))
		if err == nil {
			return C.CString(string(data))
		}
	}
	return nil
}

//export DebugGetVariables
func DebugGetVariables(variablesReference C.int) *C.char {
	if client := dap.GetClient(); client != nil {
		data, err := client.GetVariables(int(variablesReference))
		if err == nil {
			return C.CString(string(data))
		}
	}
	return nil
}

// Ownership: arguments are copied; names is a JSON string array; returns a C.malloc'd JSON {name: line} freed with FreeGoCString.
//
//export InlineValueLines
func InlineValueLines(cPath *C.char, line C.int, cNames *C.char) *C.char {
	var names []string
	src, err := lsp.DocumentContent(C.GoString(cPath))
	if err != nil || json.Unmarshal([]byte(C.GoString(cNames)), &names) != nil {
		return C.CString("{}")
	}
	b, _ := json.Marshal(goast.InlineValueLines(src, int(line), names))
	return C.CString(string(b))
}

// Ownership: returns a C.malloc'd JSON array of debuggable Go processes freed with FreeGoCString.
//
//export ListGoProcesses
func ListGoProcesses() *C.char {
	return C.CString(dap.ListDebuggableProcesses())
}

// Ownership: returns a C.malloc'd JSON VariablePayloadInspection freed with FreeGoCString.
//
//export InspectRawVariablePayload
func InspectRawVariablePayload(cTyp, cValue *C.char) *C.char {
	var typ, value string
	if cTyp != nil {
		typ = C.GoString(cTyp)
	}
	if cValue != nil {
		value = C.GoString(cValue)
	}
	res := dap.InspectRawVariablePayload(typ, value)
	b, err := json.Marshal(res)
	if err != nil {
		return C.CString("{}")
	}
	return C.CString(string(b))
}
