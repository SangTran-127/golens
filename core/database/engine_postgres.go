package database

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgconn/ctxwatch"
)

type pgConn struct {
	tunnelHold
	pc      *pgconn.PgConn
	mu      sync.Mutex
	notices []string
}

func pgQuote(v string) string {
	return "'" + strings.ReplaceAll(strings.ReplaceAll(v, `\`, `\\`), `'`, `\'`) + "'"
}

func pgConnString(o dialOptions) string {
	d := o.def
	mode := d.SSL.Mode
	if mode == "" {
		mode = "prefer"
	}
	parts := []string{
		"host=" + pgQuote(d.Host),
		"port=" + strconv.Itoa(d.Port),
		"dbname=" + pgQuote(d.Database),
		"user=" + pgQuote(d.User),
		"sslmode=" + pgQuote(mode),
		"connect_timeout=10",
		"application_name=GoLens",
	}
	if d.SSL.RootCert != "" {
		parts = append(parts, "sslrootcert="+pgQuote(resolvePath(o.root, d.SSL.RootCert)))
	}
	if d.SSL.Cert != "" {
		parts = append(parts, "sslcert="+pgQuote(resolvePath(o.root, d.SSL.Cert)))
	}
	if d.SSL.Key != "" {
		parts = append(parts, "sslkey="+pgQuote(resolvePath(o.root, d.SSL.Key)))
	}
	return strings.Join(parts, " ")
}

func dialPostgres(ctx context.Context, o dialOptions) (engineConn, error) {
	cfg, err := pgconn.ParseConfig(pgConnString(o))
	if err != nil {
		return nil, err
	}
	cfg.Password = o.secret
	cfg.ConnectTimeout = connectTimeout
	if o.via != nil {
		cfg.Host, cfg.Port = o.via.host, uint16(o.via.port)
		for _, fb := range cfg.Fallbacks {
			fb.Host, fb.Port = o.via.host, uint16(o.via.port)
		}
	}
	if cfg.RuntimeParams == nil {
		cfg.RuntimeParams = map[string]string{}
	}
	cfg.RuntimeParams["DateStyle"] = "ISO, YMD"
	if o.def.DefaultSchema != "" {
		cfg.RuntimeParams["search_path"] = o.def.DefaultSchema
	}
	if o.def.ReadOnly || o.meta {
		cfg.RuntimeParams["default_transaction_read_only"] = "on"
	}
	c := &pgConn{}
	cfg.OnNotice = func(_ *pgconn.PgConn, n *pgconn.Notice) {
		c.mu.Lock()
		if len(c.notices) < 100 {
			c.notices = append(c.notices, n.Severity+": "+n.Message)
		}
		c.mu.Unlock()
	}
	cfg.BuildContextWatcherHandler = func(p *pgconn.PgConn) ctxwatch.Handler {
		return &pgconn.CancelRequestContextWatcherHandler{Conn: p, CancelRequestDelay: 0, DeadlineDelay: 3 * time.Second}
	}
	pc, err := pgconn.ConnectConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	c.pc = pc
	return c, nil
}

type pgCursor struct {
	rr    *pgconn.ResultReader
	cols  []Column
	oids  []uint32
	kindv []uint8
}

func pgArgs(args []any) [][]byte {
	if len(args) == 0 {
		return nil
	}
	out := make([][]byte, len(args))
	for i, a := range args {
		switch v := a.(type) {
		case string:
			out[i] = append([]byte{}, v...)
		case []byte:
			out[i] = v
		case nil:
		default:
			out[i] = []byte(fmt.Sprint(v))
		}
	}
	return out
}

func (c *pgConn) run(ctx context.Context, sql string, args []any, _ classification) (cursor, *int64, error) {
	rr := c.pc.ExecParams(ctx, sql, pgArgs(args), nil, nil, nil)
	fds := rr.FieldDescriptions()
	if len(fds) == 0 {
		tag, err := rr.Close()
		if err != nil {
			return nil, nil, err
		}
		if tag.Insert() || tag.Update() || tag.Delete() || tag.Select() || strings.HasPrefix(tag.String(), "MERGE") || strings.HasPrefix(tag.String(), "COPY") {
			n := tag.RowsAffected()
			return nil, &n, nil
		}
		return nil, nil, nil
	}
	cur := &pgCursor{rr: rr}
	for _, fd := range fds {
		t := pgTypeFor(fd.DataTypeOID)
		cur.cols = append(cur.cols, Column{Name: fd.Name, DBType: t.name, Kind: KindName(t.kind)})
		cur.oids = append(cur.oids, fd.DataTypeOID)
		cur.kindv = append(cur.kindv, t.kind)
	}
	return cur, nil, nil
}

func (c *pgCursor) columns() []Column { return c.cols }
func (c *pgCursor) kinds() []uint8    { return c.kindv }

func (c *pgCursor) next(ch *chunk) (bool, error) {
	if !c.rr.NextRow() {
		_, err := c.rr.Close()
		return false, err
	}
	for i, v := range c.rr.Values() {
		if v == nil {
			ch.setNull(i)
			continue
		}
		ch.setValue(i, appendPGText(ch.cols[i].data, c.oids[i], c.kindv[i], v))
	}
	ch.endRow()
	return true, nil
}

func (c *pgCursor) close(bool) error {
	_, err := c.rr.Close()
	return err
}

func (c *pgConn) interrupt(_ *dataSource, cancel context.CancelFunc) { cancel() }

func (c *pgConn) txStatus(string) string {
	switch c.pc.TxStatus() {
	case 'T':
		return "active"
	case 'E':
		return "failed"
	}
	return "idle"
}

func (c *pgConn) serverVersion(context.Context) (string, error) {
	v := c.pc.ParameterStatus("server_version")
	if i := strings.IndexByte(v, ' '); i > 0 {
		v = v[:i]
	}
	return fmt.Sprintf("PostgreSQL %s", v), nil
}

func (c *pgConn) currentSchema(ctx context.Context) string {
	v, err := queryValue(ctx, c, "SELECT current_schema()")
	if err != nil {
		return ""
	}
	return v
}

func (c *pgConn) takeNotices() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := c.notices
	c.notices = nil
	return n
}

func (c *pgConn) broken() bool { return c.pc.IsClosed() }

func (c *pgConn) close() {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = c.pc.Close(ctx)
	c.releaseTunnel()
}
