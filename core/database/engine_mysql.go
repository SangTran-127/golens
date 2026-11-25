package database

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"database/sql/driver"
	"errors"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/go-sql-driver/mysql"
)

type quietLogger struct{}

func (quietLogger) Print(...any) {}

type mysqlConn struct {
	tunnelHold
	mu      sync.Mutex
	dc      driver.Conn
	id      string
	version string
	dead    bool
}

func mysqlTLS(o dialOptions) (*tls.Config, string, error) {
	d := o.def
	var certs []tls.Certificate
	if d.SSL.Cert != "" && d.SSL.Key != "" {
		cert, err := tls.LoadX509KeyPair(resolvePath(o.root, d.SSL.Cert), resolvePath(o.root, d.SSL.Key))
		if err != nil {
			return nil, "", err
		}
		certs = []tls.Certificate{cert}
	}
	var roots *x509.CertPool
	if d.SSL.RootCert != "" {
		pem, err := os.ReadFile(resolvePath(o.root, d.SSL.RootCert))
		if err != nil {
			return nil, "", err
		}
		roots = x509.NewCertPool()
		if !roots.AppendCertsFromPEM(pem) {
			return nil, "", errors.New("tls: the CA file has no PEM certificates")
		}
	}
	switch d.SSL.Mode {
	case "", "disable":
		return nil, "false", nil
	case "prefer":
		if certs == nil {
			return nil, "preferred", nil
		}
		return &tls.Config{InsecureSkipVerify: true, Certificates: certs}, "", nil
	case "require":
		return &tls.Config{InsecureSkipVerify: true, Certificates: certs}, "", nil
	case "verify-ca":
		return &tls.Config{InsecureSkipVerify: true, Certificates: certs, VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
			if len(raw) == 0 {
				return errors.New("tls: the server sent no certificate")
			}
			leaf, err := x509.ParseCertificate(raw[0])
			if err != nil {
				return err
			}
			inter := x509.NewCertPool()
			for _, r := range raw[1:] {
				if c, err := x509.ParseCertificate(r); err == nil {
					inter.AddCert(c)
				}
			}
			_, err = leaf.Verify(x509.VerifyOptions{Roots: roots, Intermediates: inter})
			return err
		}}, "", nil
	}
	return &tls.Config{RootCAs: roots, Certificates: certs, ServerName: d.Host}, "", nil
}

func dialMySQL(ctx context.Context, o dialOptions) (engineConn, error) {
	cfg := mysql.NewConfig()
	cfg.User = o.def.User
	cfg.Passwd = o.secret
	cfg.Net = "tcp"
	cfg.Addr = net.JoinHostPort(o.def.Host, strconv.Itoa(o.def.Port))
	if o.via != nil {
		cfg.Addr = net.JoinHostPort(o.via.host, strconv.Itoa(o.via.port))
	}
	cfg.DBName = o.def.DefaultSchema
	if cfg.DBName == "" {
		cfg.DBName = o.def.Database
	}
	cfg.Timeout = connectTimeout
	cfg.Logger = quietLogger{}
	cfg.MultiStatements = false
	cfg.InterpolateParams = false
	cfg.ParseTime = false
	cfg.ClientFoundRows = true
	tlsCfg, name, err := mysqlTLS(o)
	if err != nil {
		return nil, err
	}
	cfg.TLS = tlsCfg
	cfg.TLSConfig = name
	cfg.Params = map[string]string{"time_zone": "'+00:00'"}
	delete(cfg.Params, "time_zone")
	connector, err := mysql.NewConnector(cfg)
	if err != nil {
		return nil, err
	}
	dc, err := connector.Connect(ctx)
	if err != nil {
		return nil, err
	}
	c := &mysqlConn{dc: dc}
	if o.def.ReadOnly || o.meta {
		if _, _, err := c.run(ctx, "SET SESSION TRANSACTION READ ONLY", nil, classification{kind: "session"}); err != nil {
			dc.Close()
			return nil, err
		}
	}
	rows, err := queryAll(ctx, c, "SELECT CONNECTION_ID(), VERSION()")
	if err != nil || len(rows) == 0 {
		dc.Close()
		if err == nil {
			err = errNoRows
		}
		return nil, err
	}
	c.id, c.version = rows[0][0], rows[0][1]
	return c, nil
}

func (c *mysqlConn) mariaDB() bool { return strings.Contains(strings.ToLower(c.version), "mariadb") }

func namedArgs(args []any) []driver.NamedValue {
	out := make([]driver.NamedValue, len(args))
	for i, a := range args {
		out[i] = driver.NamedValue{Ordinal: i + 1, Value: a}
	}
	return out
}

type stmtRows struct {
	driver.Rows
	stmt driver.Stmt
}

func (r *stmtRows) Close() error {
	err := r.Rows.Close()
	_ = r.stmt.Close()
	return err
}

func (r *stmtRows) ColumnTypeDatabaseTypeName(i int) string {
	if t, ok := r.Rows.(driver.RowsColumnTypeDatabaseTypeName); ok {
		return t.ColumnTypeDatabaseTypeName(i)
	}
	return ""
}

func (r *stmtRows) ColumnTypeNullable(i int) (bool, bool) {
	if t, ok := r.Rows.(driver.RowsColumnTypeNullable); ok {
		return t.ColumnTypeNullable(i)
	}
	return false, false
}

func (c *mysqlConn) runPrepared(ctx context.Context, sql string, args []any, cl classification) (cursor, *int64, error) {
	st, err := c.dc.(driver.ConnPrepareContext).PrepareContext(ctx, sql)
	if err != nil {
		c.markDead(err)
		return nil, nil, err
	}
	if !cl.returnsRows {
		res, err := st.(driver.StmtExecContext).ExecContext(ctx, namedArgs(args))
		_ = st.Close()
		if err != nil {
			c.markDead(err)
			return nil, nil, err
		}
		n, err := res.RowsAffected()
		if err != nil {
			return nil, nil, nil
		}
		return nil, &n, nil
	}
	rows, err := st.(driver.StmtQueryContext).QueryContext(ctx, namedArgs(args))
	if err != nil {
		_ = st.Close()
		c.markDead(err)
		return nil, nil, err
	}
	if len(rows.Columns()) == 0 {
		_ = rows.Close()
		_ = st.Close()
		return nil, nil, nil
	}
	return newSQLCursor(ctx, &stmtRows{Rows: rows, stmt: st}, EngineMySQL), nil, nil
}

func (c *mysqlConn) run(ctx context.Context, sql string, args []any, cl classification) (cursor, *int64, error) {
	if len(args) > 0 {
		return c.runPrepared(ctx, sql, args, cl)
	}
	if !cl.returnsRows {
		res, err := c.dc.(driver.ExecerContext).ExecContext(ctx, sql, nil)
		if err != nil {
			c.markDead(err)
			return nil, nil, err
		}
		n, err := res.RowsAffected()
		if err != nil {
			return nil, nil, nil
		}
		return nil, &n, nil
	}
	rows, err := c.dc.(driver.QueryerContext).QueryContext(ctx, sql, nil)
	if err != nil {
		c.markDead(err)
		return nil, nil, err
	}
	if len(rows.Columns()) == 0 {
		_ = rows.Close()
		return nil, nil, nil
	}
	return newSQLCursor(ctx, rows, EngineMySQL), nil, nil
}

func (c *mysqlConn) markDead(err error) {
	if errors.Is(err, driver.ErrBadConn) || errors.Is(err, mysql.ErrInvalidConn) || errors.Is(err, context.Canceled) {
		c.mu.Lock()
		c.dead = true
		c.mu.Unlock()
	}
}

func (c *mysqlConn) interrupt(ds *dataSource, cancel context.CancelFunc) {
	go func() {
		ctx, done := context.WithTimeout(context.Background(), 3*time.Second)
		defer done()
		if ds == nil || c.id == "" || ds.killQuery(ctx, c.id) != nil {
			cancel()
			c.mu.Lock()
			c.dead = true
			c.mu.Unlock()
		}
	}()
}

func (c *mysqlConn) txStatus(tracked string) string { return tracked }

func (c *mysqlConn) serverVersion(ctx context.Context) (string, error) {
	v, err := queryValue(ctx, c, "SELECT VERSION()")
	if err != nil {
		return "", err
	}
	if strings.Contains(strings.ToLower(v), "mariadb") {
		v, _, _ = strings.Cut(v, "-")
		return "MariaDB " + v, nil
	}
	return "MySQL " + v, nil
}

func (c *mysqlConn) currentSchema(ctx context.Context) string {
	v, _ := queryValue(ctx, c, "SELECT DATABASE()")
	return v
}

func (c *mysqlConn) takeNotices() []string { return nil }

func (c *mysqlConn) broken() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.dead
}

func (c *mysqlConn) close() {
	c.mu.Lock()
	c.dead = true
	_ = c.dc.Close()
	c.mu.Unlock()
	c.releaseTunnel()
}
