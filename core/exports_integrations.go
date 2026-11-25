package main

import "C"

import (
	"encoding/json"

	"golens/core/docker"
	"golens/core/goast"
	"golens/core/httpfile"
	"golens/core/remote"
	"golens/core/sqlc"
)

// Ownership: returns a C.malloc'd JSON array of HTTPRouteLens freed with FreeGoCString.
//
//export ScanGoHTTPRoutes
func ScanGoHTTPRoutes(cSrc *C.char) *C.char {
	var src string
	if cSrc != nil {
		src = C.GoString(cSrc)
	}
	routes, err := goast.ScanGoHTTPRoutes(src)
	if err != nil || routes == nil {
		return C.CString("[]")
	}
	b, err := json.Marshal(routes)
	if err != nil {
		return C.CString("[]")
	}
	return C.CString(string(b))
}

// Ownership: returns a C.malloc'd JSON HTTPExecutionResult freed with FreeGoCString.
//
//export ExecuteGoHTTPRequest
func ExecuteGoHTTPRequest(cURL, cMethod, cHeadersJSON, cBody *C.char, timeoutSec C.int) *C.char {
	var targetURL, method, headersJSON, body string
	if cURL != nil {
		targetURL = C.GoString(cURL)
	}
	if cMethod != nil {
		method = C.GoString(cMethod)
	}
	if cHeadersJSON != nil {
		headersJSON = C.GoString(cHeadersJSON)
	}
	if cBody != nil {
		body = C.GoString(cBody)
	}
	res, err := goast.ExecuteGoHTTPRequest(targetURL, method, headersJSON, body, int(timeoutSec))
	if err != nil {
		errRes := goast.HTTPExecutionResult{
			StatusCode: 0,
			DurationMs: 0,
			Headers:    map[string]string{},
			Body:       err.Error(),
		}
		b, _ := json.Marshal(errRes)
		return C.CString(string(b))
	}
	b, err := json.Marshal(res)
	if err != nil {
		return C.CString(`{"statusCode":0,"durationMs":0,"headers":{},"body":"failed to encode response"}`)
	}
	return C.CString(string(b))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON outline freed with FreeGoCString.
//
//export HTTPFileOutline
func HTTPFileOutline(cPath, cContent, cRoot *C.char) *C.char {
	path, content, root := C.GoString(cPath), C.GoString(cContent), C.GoString(cRoot)
	out := struct {
		httpfile.File
		Environments httpfile.Environments `json:"environments"`
	}{httpfile.Parse(content), httpfile.LoadEnvironments(path, root)}
	b, err := json.Marshal(out)
	if err != nil {
		return C.CString(`{"requests":[],"variables":[],"environments":{"names":[],"issues":[]}}`)
	}
	return C.CString(string(b))
}

// Ownership: argument is copied; blocks until the request finishes; returns a C.malloc'd JSON RunResult freed with FreeGoCString.
//
//export HTTPFileRun
func HTTPFileRun(cInput *C.char) *C.char {
	var in httpfile.RunInput
	if err := json.Unmarshal([]byte(C.GoString(cInput)), &in); err != nil {
		return C.CString(`{"error":{"kind":"parse","message":"GoLens could not read the request."}}`)
	}
	b, err := json.Marshal(httpfile.Run(in))
	if err != nil {
		return C.CString(`{"error":{"kind":"parse","message":"GoLens could not encode the response."}}`)
	}
	return C.CString(string(b))
}

// Ownership: argument is copied.
//
//export HTTPFileCancel
func HTTPFileCancel(cRunID *C.char) C.int {
	if httpfile.Cancel(C.GoString(cRunID)) {
		return 1
	}
	return 0
}

// Ownership: arguments are copied; returns a C.malloc'd JSON {findings} freed with FreeGoCString.
//
//export InspectDockerfile
func InspectDockerfile(cPath, cContent *C.char) *C.char {
	return C.CString(docker.InspectJSON(C.GoString(cPath), C.GoString(cContent)))
}

// Ownership: dir is copied; returns a C.malloc'd JSON EngineStatus freed with FreeGoCString. Blocks up to ~5 s.
//
//export DockerEngineStatus
func DockerEngineStatus(cDir *C.char) *C.char {
	return C.CString(docker.StatusJSON(C.GoString(cDir)))
}

// Ownership: path is copied; returns a C.malloc'd JSON ComposeResult freed with FreeGoCString. Blocks up to ~20 s.
//
//export ValidateComposeFile
func ValidateComposeFile(cComposePath *C.char) *C.char {
	return C.CString(docker.ValidateComposeJSON(C.GoString(cComposePath)))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON GenerateResult freed with FreeGoCString. Scans the module.
//
//export GenerateDockerfile
func GenerateDockerfile(cContextDir, cOptionsJSON *C.char) *C.char {
	return C.CString(docker.GenerateJSON(C.GoString(cContextDir), C.GoString(cOptionsJSON)))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON {name, locations} freed with FreeGoCString.
//
//export SqlcQueryForGo
func SqlcQueryForGo(cGenPath *C.char, cLine C.int, cRoot, cOverlaysJSON *C.char) *C.char {
	return C.CString(sqlc.QueryForGoJSON(C.GoString(cGenPath), int(cLine), C.GoString(cRoot), C.GoString(cOverlaysJSON)))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON {configDir, generatedFiles, queries} freed with FreeGoCString.
//
//export SqlcQueriesInFile
func SqlcQueriesInFile(cSQLPath, cContent, cRoot, cOverlaysJSON *C.char) *C.char {
	return C.CString(sqlc.QueriesInFileJSON(C.GoString(cSQLPath), C.GoString(cContent), C.GoString(cRoot), C.GoString(cOverlaysJSON)))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON {file, services, error} freed with FreeGoCString. Blocks up to ~20 s.
//
//export ComposeServices
func ComposeServices(cRoot, cFile *C.char) *C.char {
	return C.CString(remote.ComposeServicesJSON(C.GoString(cRoot), C.GoString(cFile)))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON CheckResult freed with FreeGoCString. Blocks up to ~50 s.
//
//export RemoteCheckTarget
func RemoteCheckTarget(cRoot, cTargetJSON *C.char) *C.char {
	return C.CString(remote.CheckJSON(C.GoString(cRoot), C.GoString(cTargetJSON)))
}

// Ownership: arguments are copied; starts the fix (startService, installDelve) as a console run and returns its id, or 0.
//
//export RemoteFix
func RemoteFix(cRoot, cTargetJSON, cFix *C.char) C.longlong {
	return C.longlong(remote.Fix(C.GoString(cRoot), C.GoString(cTargetJSON), C.GoString(cFix)))
}
