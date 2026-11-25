package database

import (
	"errors"
	"fmt"
	"strings"

	"modernc.org/sqlite"
)

func sqliteError(err error, detail string) *Error {
	var se *sqlite.Error
	if !errors.As(err, &se) {
		return nil
	}
	kind := "server"
	switch se.Code() & 0xff {
	case 9:
		kind = "cancelled"
	case 8:
		kind = "readOnly"
	case 19:
		kind = "constraint"
	case 23, 3:
		kind = "permission"
	case 14:
		kind = "connect"
	case 11, 26:
		kind = "connect"
	case 1:
		if strings.Contains(detail, "syntax error") || strings.Contains(detail, "no such") ||
			strings.Contains(detail, "incomplete input") || strings.Contains(detail, "unrecognized token") ||
			strings.Contains(detail, "ambiguous column") || strings.Contains(detail, "has no column") {
			kind = "syntax"
		}
	}
	e := newError(kind, "")
	if kind == "connect" {
		e.Message = "GoLens could not open the SQLite file. Check the path and that the file is a SQLite database."
	}
	if sqliteBusy(err) {
		e.Message = "Another connection kept this SQLite file locked, so GoLens stopped waiting after 5 seconds. Fetch the rest of any partial result on this file or close it, or close the other app using the file, then try again."
	}
	e.Detail = detail
	e.Code = fmt.Sprintf("SQLite %d", se.Code())
	return e
}

func sqliteBusy(err error) bool {
	var se *sqlite.Error
	if !errors.As(err, &se) {
		return false
	}
	code := se.Code() & 0xff
	return code == 5 || code == 6
}
