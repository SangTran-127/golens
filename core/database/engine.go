package database

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

const connectTimeout = 10 * time.Second

type cursor interface {
	columns() []Column
	kinds() []uint8
	next(ch *chunk) (bool, error)
	close(cancel bool) error
}

type engineConn interface {
	run(ctx context.Context, sql string, args []any, c classification) (cursor, *int64, error)
	interrupt(ds *dataSource, cancel context.CancelFunc)
	txStatus(tracked string) string
	serverVersion(ctx context.Context) (string, error)
	currentSchema(ctx context.Context) string
	takeNotices() []string
	broken() bool
	close()
}

type forward struct {
	host string
	port int
}

type dialOptions struct {
	def    Definition
	root   string
	secret string
	meta   bool
	via    *forward
}

func dial(ctx context.Context, o dialOptions) (engineConn, error) {
	if !usesTunnel(o.def) {
		return dialEngine(ctx, o)
	}
	t, err := tunnels.acquire(ctx, o.def)
	if err != nil {
		return nil, err
	}
	o.via = &forward{host: "127.0.0.1", port: t.port}
	c, err := dialEngine(ctx, o)
	if err != nil {
		tunnels.release(t)
		return nil, err
	}
	if h, ok := c.(tunnelHolder); ok {
		h.holdTunnel(t)
	} else {
		tunnels.release(t)
	}
	return c, nil
}

func dialEngine(ctx context.Context, o dialOptions) (engineConn, error) {
	ctx, cancel := context.WithTimeout(ctx, connectTimeout)
	defer cancel()
	switch o.def.Engine {
	case EnginePostgres:
		return dialPostgres(ctx, o)
	case EngineMySQL:
		return dialMySQL(ctx, o)
	case EngineSQLite:
		return dialSQLite(ctx, o)
	}
	return nil, fmt.Errorf("unknown engine %q", o.def.Engine)
}

func resolvePath(root, p string) string {
	if p == "" || filepath.IsAbs(p) {
		return p
	}
	if len(p) > 1 && p[0] == '~' && p[1] == '/' {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, p[2:])
		}
	}
	return filepath.Join(root, p)
}

func queryAll(ctx context.Context, c engineConn, sql string) ([][]string, error) {
	return queryArgs(ctx, c, sql, nil)
}

func queryArgs(ctx context.Context, c engineConn, sql string, args []any) ([][]string, error) {
	cur, _, err := c.run(ctx, sql, args, classification{kind: "select", returnsRows: true})
	if err != nil {
		return nil, err
	}
	if cur == nil {
		return nil, nil
	}
	var out [][]string
	ncols := len(cur.columns())
	for {
		ch := newChunk(ncols)
		var more bool
		for !ch.full() {
			more, err = cur.next(ch)
			if err != nil || !more {
				break
			}
		}
		for r := 0; r < ch.rows; r++ {
			row := make([]string, ncols)
			for c := range row {
				v, null := ch.cols[c].cell(r)
				if !null {
					row[c] = string(v)
				}
			}
			out = append(out, row)
		}
		if err != nil {
			_ = cur.close(true)
			return nil, err
		}
		if !more {
			break
		}
	}
	return out, cur.close(false)
}

var errNoRows = errors.New("no rows")

func queryValue(ctx context.Context, c engineConn, sql string) (string, error) {
	rows, err := queryAll(ctx, c, sql)
	if err != nil {
		return "", err
	}
	if len(rows) == 0 || len(rows[0]) == 0 {
		return "", errNoRows
	}
	return rows[0][0], nil
}
