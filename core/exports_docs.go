package main

import "C"

import (
	"encoding/json"
	"strings"

	"golens/core/docs"
)

type docsTargetRequest struct {
	GOOS              string `json:"goos"`
	GOARCH            string `json:"goarch"`
	Tags              string `json:"tags"`
	IncludeStd        bool   `json:"includeStd"`
	IncludeUnexported bool   `json:"includeUnexported"`
	Scope             string `json:"scope"`
}

func decodeDocsRequest(targetJSON string) (docs.Options, string) {
	var req docsTargetRequest
	if strings.TrimSpace(targetJSON) != "" {
		_ = json.Unmarshal([]byte(targetJSON), &req)
	}
	return docs.Options{
		Target: docs.Target{
			GOOS:       req.GOOS,
			GOARCH:     req.GOARCH,
			Tags:       req.Tags,
			IncludeStd: req.IncludeStd,
		},
		IncludeStd:        req.IncludeStd,
		IncludeUnexported: req.IncludeUnexported,
	}, req.Scope
}

func marshalDocsJSON(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		return C.CString(`{"error":"GoLens could not encode the documentation response."}`)
	}
	return C.CString(string(b))
}

//export DocsListPackages
func DocsListPackages(cReqID *C.char, cRoot *C.char, cTargetJSON *C.char) *C.char {
	opts, _ := decodeDocsRequest(C.GoString(cTargetJSON))
	return marshalDocsJSON(docs.DefaultService.ListPackages(C.GoString(cReqID), C.GoString(cRoot), opts))
}

//export DocsPackagePage
func DocsPackagePage(cReqID *C.char, cRoot *C.char, cImportPath *C.char, cTargetJSON *C.char, cOverlayJSON *C.char) *C.char {
	opts, _ := decodeDocsRequest(C.GoString(cTargetJSON))
	if raw := strings.TrimSpace(C.GoString(cOverlayJSON)); raw != "" {
		var overlay map[string]string
		if json.Unmarshal([]byte(raw), &overlay) == nil {
			opts.Overlay = overlay
		}
	}
	return marshalDocsJSON(docs.DefaultService.LoadPackagePage(C.GoString(cReqID), C.GoString(cRoot), C.GoString(cImportPath), opts))
}

//export DocsSearch
func DocsSearch(cReqID *C.char, cRoot *C.char, cTargetJSON *C.char, cQuery *C.char, limit C.int) *C.char {
	opts, scope := decodeDocsRequest(C.GoString(cTargetJSON))
	return marshalDocsJSON(docs.DefaultService.Search(C.GoString(cReqID), C.GoString(cRoot), opts, scope, C.GoString(cQuery), int(limit)))
}

//export DocsCancel
func DocsCancel(cReqID *C.char) {
	docs.DefaultService.Cancel(C.GoString(cReqID))
}

//export DocsInvalidate
func DocsInvalidate(cRoot *C.char) {
	docs.DefaultService.Invalidate(C.GoString(cRoot))
}
