package database

import (
	"context"
	"database/sql/driver"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"sync"

	"modernc.org/sqlite"
)

type sqlCursor struct {
	rows   driver.Rows
	cols   []Column
	kindOf []uint8
	dest   []driver.Value
	ctx    context.Context
	first  bool
	sqlite bool
}

func newSQLCursor(ctx context.Context, rows driver.Rows, engine string) *sqlCursor {
	names := rows.Columns()
	c := &sqlCursor{rows: rows, ctx: ctx, dest: make([]driver.Value, len(names)), first: true, sqlite: engine == EngineSQLite}
	typed, _ := rows.(driver.RowsColumnTypeDatabaseTypeName)
	nullable, _ := rows.(driver.RowsColumnTypeNullable)
	for i, n := range names {
		col := Column{Name: n}
		if typed != nil {
			col.DBType = typed.ColumnTypeDatabaseTypeName(i)
		}
		if nullable != nil {
			if v, ok := nullable.ColumnTypeNullable(i); ok && !c.sqlite {
				col.Nullable = &v
			}
		}
		var k uint8
		if c.sqlite {
			k = sqliteKind(col.DBType)
		} else {
			k = mysqlTypeKind(col.DBType)
		}
		c.kindOf = append(c.kindOf, k)
		c.cols = append(c.cols, col)
	}
	return c
}

func (c *sqlCursor) columns() []Column {
	for i := range c.cols {
		c.cols[i].Kind = KindName(c.kindOf[i])
		if c.cols[i].DBType == "" {
			c.cols[i].DBType = KindName(c.kindOf[i])
		}
	}
	return c.cols
}

func (c *sqlCursor) kinds() []uint8 { return c.kindOf }

func (c *sqlCursor) next(ch *chunk) (bool, error) {
	if err := c.ctx.Err(); err != nil {
		return false, err
	}
	if err := c.rows.Next(c.dest); err != nil {
		if errors.Is(err, io.EOF) {
			return false, nil
		}
		return false, err
	}
	if c.first {
		c.first = false
		for i, v := range c.dest {
			if c.kindOf[i] == KindUnknown && v != nil {
				c.kindOf[i] = kindOfValue(v)
			}
		}
	}
	for i, v := range c.dest {
		if v == nil {
			ch.setNull(i)
			continue
		}
		ch.setValue(i, appendValue(ch.cols[i].data, c.kindOf[i], v))
	}
	ch.endRow()
	return true, nil
}

func (c *sqlCursor) close(bool) error { return c.rows.Close() }

type sqliteConn struct {
	mu      sync.Mutex
	dc      driver.Conn
	dead    bool
	tracked string
}

func sqliteDSN(o dialOptions) (string, error) {
	path := resolvePath(o.root, o.def.SQLitePath)
	if path == "" {
		return "", errors.New("no SQLite file")
	}
	mode := "rw"
	if o.def.ReadOnly {
		mode = "ro"
	}
	if _, err := os.Stat(path); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return "", err
		}
		if !o.def.SQLiteCreate || o.def.ReadOnly {
			return "", &missingFileError{path: o.def.SQLitePath}
		}
		mode = "rwc"
	}
	q := url.Values{}
	q.Set("mode", mode)
	q.Add("_pragma", "busy_timeout(5000)")
	q.Add("_pragma", "foreign_keys(1)")
	q.Add("_pragma", "cache_size(-512)")
	if o.def.ReadOnly || o.meta {
		q.Add("_pragma", "query_only(1)")
	}
	u := url.URL{Scheme: "file", Path: path, RawQuery: q.Encode()}
	return u.String(), nil
}

type missingFileError struct{ path string }

func (e *missingFileError) Error() string { return "SQLite file does not exist: " + e.path }

func dialSQLite(ctx context.Context, o dialOptions) (engineConn, error) {
	dsn, err := sqliteDSN(o)
	if err != nil {
		return nil, err
	}
	dc, err := (&sqlite.Driver{}).Open(dsn)
	if err != nil {
		return nil, err
	}
	c := &sqliteConn{dc: dc, tracked: "idle"}
	if _, err := queryValue(ctx, c, "SELECT count(*) FROM sqlite_schema"); err != nil {
		dc.Close()
		return nil, err
	}
	return c, nil
}

func (c *sqliteConn) run(ctx context.Context, sql string, args []any, cl classification) (cursor, *int64, error) {
	named := namedArgs(args)
	if !cl.returnsRows {
		ex, ok := c.dc.(driver.ExecerContext)
		if !ok {
			return nil, nil, errors.New("driver cannot execute")
		}
		res, err := ex.ExecContext(ctx, sql, named)
		if err != nil {
			return nil, nil, err
		}
		n, err := res.RowsAffected()
		if err != nil {
			return nil, nil, nil
		}
		return nil, &n, nil
	}
	q, ok := c.dc.(driver.QueryerContext)
	if !ok {
		return nil, nil, errors.New("driver cannot query")
	}
	rows, err := q.QueryContext(ctx, sql, named)
	if err != nil {
		return nil, nil, err
	}
	if len(rows.Columns()) == 0 {
		_ = rows.Close()
		return nil, nil, nil
	}
	return newSQLCursor(ctx, rows, EngineSQLite), nil, nil
}

func (c *sqliteConn) interrupt(_ *dataSource, cancel context.CancelFunc) { cancel() }

func (c *sqliteConn) txStatus(tracked string) string { return tracked }

func (c *sqliteConn) serverVersion(ctx context.Context) (string, error) {
	v, err := queryValue(ctx, c, "SELECT sqlite_version()")
	if err != nil {
		return "", err
	}
	return "SQLite " + v, nil
}

func (c *sqliteConn) currentSchema(context.Context) string { return "main" }

func (c *sqliteConn) takeNotices() []string { return nil }

func (c *sqliteConn) broken() bool { return c.dead }

func (c *sqliteConn) close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.dead {
		c.dead = true
		_ = c.dc.Close()
	}
}

func sqliteMissingFileError(e *missingFileError) *Error {
	return &Error{Kind: "connect", Message: fmt.Sprintf("The SQLite file %s does not exist. Check the path, or turn on Create the file if it does not exist in Edit Data Source.", e.path)}
}
