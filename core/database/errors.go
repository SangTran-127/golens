package database

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"regexp"
	"strconv"
	"strings"
	"syscall"

	"github.com/go-sql-driver/mysql"
	"github.com/jackc/pgx/v5/pgconn"
)

var errorKinds = []string{
	"needsSecret", "connect", "auth", "tls", "timeout", "syntax", "permission", "constraint",
	"readOnly", "cancelled", "connectionLost", "server", "internal",
	"needsParameters", "transactionOpen", "unsupported", "tooLarge", "conflict",
}

var defaultMessages = map[string]string{
	"needsSecret":     "Enter the password for this data source to connect.",
	"connect":         "GoLens could not reach the database server. Check that it is running and that the host and port are right.",
	"auth":            "The server did not accept the user name or password. Check them in Edit Data Source.",
	"tls":             "The secure connection to the server failed. Check the SSL mode and certificate files in Edit Data Source.",
	"timeout":         "The server did not answer within 10 seconds. Check the host and your network.",
	"syntax":          "The database could not run the statement as written. Fix it and run it again.",
	"permission":      "The database user is not allowed to run this statement.",
	"constraint":      "The statement would break a rule of the database, such as a key or a check.",
	"readOnly":        "This data source is read-only, so GoLens did not run the statement. Turn off Read-only in Edit Data Source to allow writes.",
	"cancelled":       "The statement was canceled.",
	"connectionLost":  "The connection to the server was lost. Run the statement again to reconnect.",
	"server":          "The database reported an error while running the statement.",
	"internal":        "GoLens could not complete the request because of an internal error.",
	"needsParameters": "Enter a value for every parameter to run this statement.",
	"transactionOpen": "Commit or roll back the open transaction first.",
	"unsupported":     "This database can't do that.",
	"tooLarge":        "The result is too large to copy. Export it to a file instead.",
	"conflict":        "A row no longer matches what GoLens read, so nothing was saved. Reload the table and make the change again.",
}

func errorFor(kind string) *Error {
	return &Error{Kind: kind, Message: defaultMessages[kind]}
}

func newError(kind, message string) *Error {
	if message == "" {
		message = defaultMessages[kind]
	}
	return &Error{Kind: kind, Message: message}
}

func redact(s, secret string) string {
	if secret != "" && len(secret) >= 1 {
		s = strings.ReplaceAll(s, secret, "•••")
	}
	return s
}

func classifyConnectError(err error, def *Definition, secret string) *Error {
	e := classifyError(err, secret)
	if sqliteBusy(err) {
		return e
	}
	if e.Kind == "server" || e.Kind == "internal" || e.Kind == "connectionLost" {
		e.Kind = "connect"
		e.Message = defaultMessages["connect"]
	}
	if e.Kind == "connect" && def.Engine != EngineSQLite {
		e.Message = fmt.Sprintf("GoLens could not reach %s. Check that the server is running and that the host and port are right.", hostPort(def))
	}
	if e.Kind == "timeout" {
		e.Message = fmt.Sprintf("%s did not answer within 10 seconds. Check the host and your network.", hostPort(def))
	}
	return e
}

func classifyError(err error, secret string) *Error {
	if err == nil {
		return nil
	}
	detail := redact(err.Error(), secret)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		e := newError(pgKind(pgErr.Code), "")
		e.Detail = redact(pgErr.Message, secret)
		if pgErr.Detail != "" {
			e.Detail += "\n" + redact(pgErr.Detail, secret)
		}
		if pgErr.Hint != "" {
			e.Detail += "\nHint: " + redact(pgErr.Hint, secret)
		}
		e.Code = "SQLSTATE " + pgErr.Code
		return e
	}
	var myErr *mysql.MySQLError
	if errors.As(err, &myErr) {
		e := newError(mysqlKind(myErr.Number), "")
		e.Detail = redact(myErr.Message, secret)
		e.Code = fmt.Sprintf("MySQL %d", myErr.Number)
		return e
	}
	if errors.Is(err, context.Canceled) {
		return &Error{Kind: "cancelled", Message: defaultMessages["cancelled"]}
	}
	var tlsErr *tls.CertificateVerificationError
	var unknownAuth x509.UnknownAuthorityError
	var hostErr x509.HostnameError
	var recordErr tls.RecordHeaderError
	if errors.As(err, &tlsErr) || errors.As(err, &unknownAuth) || errors.As(err, &hostErr) || errors.As(err, &recordErr) ||
		strings.Contains(detail, "tls:") || strings.Contains(detail, "x509:") || strings.Contains(detail, "server refused TLS") ||
		strings.Contains(detail, "TLS requested but server does not support TLS") {
		return &Error{Kind: "tls", Message: defaultMessages["tls"], Detail: detail}
	}
	if errors.Is(err, context.DeadlineExceeded) || isTimeout(err) {
		return &Error{Kind: "timeout", Message: defaultMessages["timeout"], Detail: detail}
	}
	if errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, syscall.EHOSTUNREACH) || errors.Is(err, syscall.ENETUNREACH) {
		return &Error{Kind: "connect", Message: defaultMessages["connect"], Detail: detail}
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return &Error{Kind: "connect", Message: defaultMessages["connect"], Detail: detail}
	}
	if errors.Is(err, fs.ErrNotExist) || errors.Is(err, os.ErrPermission) {
		return &Error{Kind: "connect", Message: defaultMessages["connect"], Detail: detail}
	}
	if errors.Is(err, mysql.ErrInvalidConn) || errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.EPIPE) ||
		strings.Contains(detail, "conn closed") || strings.Contains(detail, "unexpected EOF") || errors.Is(err, net.ErrClosed) {
		return &Error{Kind: "connectionLost", Message: defaultMessages["connectionLost"], Detail: detail}
	}
	if e := sqliteError(err, detail); e != nil {
		return e
	}
	return &Error{Kind: "server", Message: defaultMessages["server"], Detail: detail}
}

func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

func pgKind(code string) string {
	switch {
	case code == "57014":
		return "cancelled"
	case code == "25006":
		return "readOnly"
	case code == "42501":
		return "permission"
	case strings.HasPrefix(code, "28"):
		return "auth"
	case strings.HasPrefix(code, "23"):
		return "constraint"
	case strings.HasPrefix(code, "42"), strings.HasPrefix(code, "0A"):
		return "syntax"
	case strings.HasPrefix(code, "08"), code == "57P01", code == "57P02", code == "57P03":
		return "connectionLost"
	}
	return "server"
}

func mysqlKind(n uint16) string {
	switch n {
	case 1317, 3024:
		return "cancelled"
	case 1792, 1290, 1836:
		return "readOnly"
	case 1045, 1698, 1251:
		return "auth"
	case 1044, 1142, 1143, 1227, 1370:
		return "permission"
	case 1062, 1451, 1452, 1048, 1364, 3819, 1216, 1217:
		return "constraint"
	case 1064, 1054, 1146, 1049, 1109, 1052, 1149:
		return "syntax"
	case 2006, 2013:
		return "connectionLost"
	}
	return "server"
}

func hostPort(def *Definition) string {
	return net.JoinHostPort(def.Host, fmt.Sprint(def.Port))
}

func positionIn(text string, byteOffset int) *Position {
	if byteOffset < 0 || byteOffset > len(text) {
		return nil
	}
	line, col := 1, 1
	for _, r := range text[:byteOffset] {
		if r == '\n' {
			line++
			col = 1
		} else {
			col++
		}
	}
	return &Position{Byte: byteOffset, Line: line, Col: col}
}

var (
	mysqlNearRe  = regexp.MustCompile(`(?s)near '(.*)' at line (\d+)`)
	sqliteNearRe = regexp.MustCompile(`near "([^"]+)": syntax error`)
)

func enginePosition(e *Error, stmt string) (int, bool) {
	if e == nil || e.Detail == "" {
		return 0, false
	}
	if m := mysqlNearRe.FindStringSubmatch(e.Detail); m != nil {
		line, _ := strconv.Atoi(m[2])
		start := 0
		for i := 1; i < line; i++ {
			nl := strings.IndexByte(stmt[start:], '\n')
			if nl < 0 {
				return 0, false
			}
			start += nl + 1
		}
		if m[1] == "" {
			return len(stmt), true
		}
		if i := strings.Index(stmt[start:], m[1]); i >= 0 {
			return start + i, true
		}
		if i := strings.Index(stmt, m[1]); i >= 0 {
			return i, true
		}
		return start, true
	}
	if m := sqliteNearRe.FindStringSubmatch(e.Detail); m != nil {
		for _, t := range lex(stmt, EngineSQLite) {
			if t.kind != tSpace && t.kind != tComment && t.text(stmt) == m[1] {
				return t.start, true
			}
		}
	}
	return 0, false
}
