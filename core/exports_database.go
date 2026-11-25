package main

/*
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import (
	"encoding/json"
	"unsafe"

	"golens/core/database"
)

func dbJSON(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		return C.CString(`{"error":{"kind":"internal","message":"GoLens could not encode the database response."}}`)
	}
	return C.CString(string(b))
}

func dbBadRequest() *C.char {
	return C.CString(`{"error":{"kind":"internal","message":"GoLens could not read the database request."}}`)
}

// Ownership: arguments are copied; returns a C.malloc'd JSON {issues} freed with FreeGoCString.
//
//export DBConfigure
func DBConfigure(cRoot, cDefinitions *C.char) *C.char {
	return dbJSON(database.Configure(C.GoString(cRoot), C.GoString(cDefinitions)))
}

// Ownership: arguments are copied; the secret stays in memory only; returns a C.malloc'd JSON {ok} freed with FreeGoCString.
//
//export DBSetSecret
func DBSetSecret(cID, cSecret *C.char) *C.char {
	return dbJSON(database.SetSecret(C.GoString(cID), C.GoString(cSecret)))
}

// Ownership: argument is copied; blocks while sessions of that window close.
//
//export DBShutdownWorkspace
func DBShutdownWorkspace(cRoot *C.char) {
	database.ShutdownWorkspace(C.GoString(cRoot))
}

// Ownership: returns a C.malloc'd JSON Stats freed with FreeGoCString.
//
//export DBStats
func DBStats() *C.char {
	return dbJSON(database.GetStats())
}

// Ownership: argument is copied; blocks; returns a C.malloc'd JSON TestConnectionResult freed with FreeGoCString.
//
//export DBTestConnection
func DBTestConnection(cRequest *C.char) *C.char {
	var req database.TestConnectionRequest
	if json.Unmarshal([]byte(C.GoString(cRequest)), &req) != nil {
		return dbBadRequest()
	}
	return dbJSON(database.TestConnection(req))
}

// Ownership: argument is copied; blocks; returns a C.malloc'd JSON {ok, hadOpenTransaction} freed with FreeGoCString.
//
//export DBDisconnect
func DBDisconnect(cID *C.char) *C.char {
	return dbJSON(database.Disconnect(C.GoString(cID)))
}

// Ownership: argument is copied; blocks; returns a C.malloc'd JSON {ok, hadOpenTransaction} freed with FreeGoCString.
//
//export DBCloseConsole
func DBCloseConsole(cID *C.char, force C.int) *C.char {
	return dbJSON(database.CloseConsole(C.GoString(cID), force != 0))
}

// Ownership: arguments are copied; pure; returns a C.malloc'd JSON array freed with FreeGoCString.
//
//export DBStatements
func DBStatements(cText, cDialect *C.char) *C.char {
	return dbJSON(database.Statements(C.GoString(cText), C.GoString(cDialect)))
}

// Ownership: argument is copied; blocks; emits "database" status events; returns a C.malloc'd JSON ExecuteResponse freed with FreeGoCString.
//
//export DBExecute
func DBExecute(cRequest *C.char) *C.char {
	var req database.ExecuteRequest
	if json.Unmarshal([]byte(C.GoString(cRequest)), &req) != nil {
		return dbBadRequest()
	}
	return dbJSON(database.Execute(req))
}

// Ownership: argument is copied; returns 1 when a running statement or fetch was asked to stop.
//
//export DBCancel
func DBCancel(cID *C.char) C.int {
	if database.Cancel(C.GoString(cID)) {
		return 1
	}
	return 0
}

// Ownership: id is copied; returns a C.malloc'd GLRP page of *outLen bytes freed with FreeGoBuffer; NULL with *outLen = -1 for an unknown result.
//
//export DBFetchPage
func DBFetchPage(cID *C.char, firstRow C.int64_t, maxRows C.int32_t, outLen *C.int64_t) *C.uint8_t {
	page, ok := database.FetchPage(C.GoString(cID), int64(firstRow), int(maxRows))
	if !ok {
		*outLen = -1
		return nil
	}
	buf := (*C.uint8_t)(C.malloc(C.size_t(max(len(page), 1))))
	copy(unsafe.Slice((*byte)(unsafe.Pointer(buf)), len(page)), page)
	*outLen = C.int64_t(len(page))
	return buf
}

// Ownership: argument is copied; blocks; returns a C.malloc'd JSON FetchAllResult freed with FreeGoCString.
//
//export DBFetchAll
func DBFetchAll(cID *C.char) *C.char {
	return dbJSON(database.FetchAll(C.GoString(cID)))
}

// Ownership: arguments are copied; returns a C.malloc'd JSON SortResult freed with FreeGoCString.
//
//export DBSortResult
func DBSortResult(cID, cSort *C.char) *C.char {
	var keys []database.SortKey
	if json.Unmarshal([]byte(C.GoString(cSort)), &keys) != nil {
		return dbBadRequest()
	}
	return dbJSON(database.SortResultRows(C.GoString(cID), keys))
}

// Ownership: id is copied; returns a C.malloc'd JSON CellValue freed with FreeGoCString.
//
//export DBCellValue
func DBCellValue(cID *C.char, row C.int64_t, column C.int32_t, maxBytes C.int32_t) *C.char {
	return dbJSON(database.Cell(C.GoString(cID), int64(row), int(column), int(maxBytes)))
}

// Ownership: argument is copied; releases the result, its cursor and its spill file.
//
//export DBCloseResult
func DBCloseResult(cID *C.char) {
	database.CloseResult(C.GoString(cID))
}

// Ownership: argument is copied; blocks; returns a C.malloc'd JSON IntrospectResult freed with FreeGoCString.
//
//export DBIntrospect
func DBIntrospect(cRequest *C.char) *C.char {
	var req database.IntrospectRequest
	if json.Unmarshal([]byte(C.GoString(cRequest)), &req) != nil {
		return dbBadRequest()
	}
	return dbJSON(database.Introspect(req))
}

// Ownership: argument is copied; blocks only when a schema must be introspected; returns a C.malloc'd JSON {nodes} freed with FreeGoCString.
//
//export DBSchemaChildren
func DBSchemaChildren(cRequest *C.char) *C.char {
	var req database.SchemaChildrenRequest
	if json.Unmarshal([]byte(C.GoString(cRequest)), &req) != nil {
		return dbBadRequest()
	}
	return dbJSON(database.SchemaChildren(req))
}

// Ownership: argument is copied; never touches the network; returns a C.malloc'd JSON CompleteResult freed with FreeGoCString.
//
//export DBComplete
func DBComplete(cRequest *C.char) *C.char {
	var req database.CompleteRequest
	if json.Unmarshal([]byte(C.GoString(cRequest)), &req) != nil {
		return dbBadRequest()
	}
	return dbJSON(database.Complete(req))
}

// Ownership: argument is copied; blocks; emits "database" status events; returns a C.malloc'd JSON OpenTableResponse freed with FreeGoCString.
//
//export DBOpenTable
func DBOpenTable(cRequest *C.char) *C.char {
	var req database.OpenTableRequest
	if json.Unmarshal([]byte(C.GoString(cRequest)), &req) != nil {
		return dbBadRequest()
	}
	return dbJSON(database.OpenTable(req))
}

// Ownership: argument is copied; blocks, cancelable with DBCancel(execId); returns a C.malloc'd JSON {count, error} freed with FreeGoCString.
//
//export DBCountRows
func DBCountRows(cRequest *C.char) *C.char {
	var req database.CountRowsRequest
	if json.Unmarshal([]byte(C.GoString(cRequest)), &req) != nil {
		return dbBadRequest()
	}
	return dbJSON(database.CountRows(req))
}

// Ownership: argument is copied; never touches the network; returns a C.malloc'd JSON PlanEditsResult freed with FreeGoCString.
//
//export DBPlanEdits
func DBPlanEdits(cRequest *C.char) *C.char {
	var req database.EditRequest
	if json.Unmarshal([]byte(C.GoString(cRequest)), &req) != nil {
		return dbBadRequest()
	}
	return dbJSON(database.PlanEdits(req))
}

// Ownership: argument is copied; blocks, cancelable with DBCancel(execId); returns a C.malloc'd JSON ApplyEditsResult freed with FreeGoCString.
//
//export DBApplyEdits
func DBApplyEdits(cRequest *C.char) *C.char {
	var req database.EditRequest
	if json.Unmarshal([]byte(C.GoString(cRequest)), &req) != nil {
		return dbBadRequest()
	}
	return dbJSON(database.ApplyEdits(req))
}

// Ownership: argument is copied; blocks while it commits or rolls back; emits "database" status events; returns a C.malloc'd JSON TransactionResult freed with FreeGoCString.
//
//export DBTransaction
func DBTransaction(cRequest *C.char) *C.char {
	var req database.TransactionRequest
	if json.Unmarshal([]byte(C.GoString(cRequest)), &req) != nil {
		return dbBadRequest()
	}
	return dbJSON(database.Transaction(req))
}

// Ownership: argument is copied; blocks, cancelable with DBCancel(execId); returns a C.malloc'd JSON ExplainResult freed with FreeGoCString.
//
//export DBExplain
func DBExplain(cRequest *C.char) *C.char {
	var req database.ExplainRequest
	if json.Unmarshal([]byte(C.GoString(cRequest)), &req) != nil {
		return dbBadRequest()
	}
	return dbJSON(database.Explain(req))
}

// Ownership: argument is copied; blocks while it writes, cancelable with DBCancel(execId); returns a C.malloc'd JSON ExportResult freed with FreeGoCString.
//
//export DBExport
func DBExport(cRequest *C.char) *C.char {
	var req database.ExportRequest
	if json.Unmarshal([]byte(C.GoString(cRequest)), &req) != nil {
		return dbBadRequest()
	}
	return dbJSON(database.Export(req))
}

// Ownership: argument is copied; blocks while it reads project files, never connects or writes; returns a C.malloc'd JSON {candidates} freed with FreeGoCString.
//
//export DBDetectDataSources
func DBDetectDataSources(cRoot *C.char) *C.char {
	return dbJSON(database.DetectDataSources(C.GoString(cRoot)))
}

// Ownership: arguments are copied; pure; returns a C.malloc'd JSON {parameters} freed with FreeGoCString.
//
//export DBParameters
func DBParameters(cText, cDialect *C.char, startByte, endByte C.int64_t) *C.char {
	return dbJSON(database.Parameters(C.GoString(cText), C.GoString(cDialect), int(startByte), int(endByte)))
}

// Ownership: argument is copied; reads and rewrites the history file; returns a C.malloc'd JSON {entries, error} freed with FreeGoCString.
//
//export DBHistory
func DBHistory(cRequest *C.char) *C.char {
	var req database.HistoryRequest
	if json.Unmarshal([]byte(C.GoString(cRequest)), &req) != nil {
		return dbBadRequest()
	}
	return dbJSON(database.History(req))
}

// Ownership: argument is copied; sets the folder that holds the query history files; returns a C.malloc'd JSON {ok} freed with FreeGoCString.
//
//export DBSetHistoryDirectory
func DBSetHistoryDirectory(cDir *C.char) *C.char {
	return dbJSON(database.SetHistoryDirectory(C.GoString(cDir)))
}

//export DBGoSQLSites
func DBGoSQLSites(cPath, cContent, cRoot *C.char) *C.char {
	return dbJSON(database.GoSQLSites(C.GoString(cPath), C.GoString(cContent), C.GoString(cRoot)))
}

//export DBSqlcQuery
func DBSqlcQuery(cSQLPath, cContent *C.char, line C.int) *C.char {
	return dbJSON(database.SqlcQuery(C.GoString(cSQLPath), C.GoString(cContent), int(line)))
}

//export DBRelatedRows
func DBRelatedRows(cRequest *C.char) *C.char {
	var req database.RelatedRowsRequest
	if json.Unmarshal([]byte(C.GoString(cRequest)), &req) != nil {
		return dbBadRequest()
	}
	return dbJSON(database.RelatedRows(req))
}
