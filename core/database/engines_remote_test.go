//go:build dbengines

package database

import (
	"os"
	"strings"
	"testing"
)

func TestEngineThroughSSHTunnel(t *testing.T) {
	for _, engine := range []string{EnginePostgres, EngineMySQL} {
		t.Run(engine, func(t *testing.T) {
			useFakeSSH(t, "ok")
			e, def := engineEnv(t, engine, func(d *Definition) { d.SSH = SSH{Destination: "me@bastion"} })
			resp := run(t, e, def, "tunnel", "SELECT 41 + 1 AS answer")
			if p := mustPage(t, resp.Statements[0].ResultID, 0, 1); p.Columns[0].Values[0] != "42" {
				t.Fatalf("answer = %v", p.Columns[0].Values)
			}
			st := GetStats()
			if len(st.Tunnels) != 1 || st.Tunnels[0].DataSourceID != def.ID || st.Tunnels[0].PID <= 0 {
				t.Fatalf("stats tunnels = %+v", st.Tunnels)
			}
			pid := st.Tunnels[0].PID
			if res := Introspect(IntrospectRequest{DataSourceID: def.ID}); res.Error != nil {
				t.Fatalf("introspect through the tunnel: %+v", res.Error)
			}
			if n := len(GetStats().Tunnels); n != 1 {
				t.Fatalf("the metadata pool started a second tunnel: %d", n)
			}
			Disconnect(def.ID)
			if !processGone(pid) {
				t.Fatal("ssh outlived Disconnect")
			}
			if n := len(GetStats().Tunnels); n != 0 {
				t.Fatalf("tunnels after Disconnect: %d", n)
			}
		})
	}
}

func TestEngineTestConnectionThroughTunnelStopsIt(t *testing.T) {
	fake := useFakeSSH(t, "ok")
	def, secret := engineDef(t, EnginePostgres)
	def.SSH = SSH{Destination: "me@bastion"}
	res := TestConnection(TestConnectionRequest{Definition: def, Secret: secret})
	if !res.OK {
		t.Fatalf("test connection: %+v", res.Error)
	}
	if n := len(GetStats().Tunnels); n != 0 {
		t.Fatalf("Test Connection left %d tunnels", n)
	}
	b, _ := os.ReadFile(fake.log)
	if !strings.Contains(string(b), "me@bastion") {
		t.Fatal("Test Connection did not use ssh")
	}
}

func TestEngineRelatedRowsPostgres(t *testing.T) {
	e, def := engineEnv(t, EnginePostgres, nil)
	run(t, e, def, "setup", `DROP TABLE IF EXISTS rel_refunds, rel_orders, rel_customers;
CREATE TABLE rel_customers (id bigint PRIMARY KEY, name text);
CREATE TABLE rel_orders (id bigint PRIMARY KEY, customer_id bigint REFERENCES rel_customers(id));
CREATE TABLE rel_refunds (id bigint PRIMARY KEY, order_id bigint REFERENCES rel_orders(id));
INSERT INTO rel_customers VALUES (7, 'Ada');
INSERT INTO rel_orders VALUES (70, 7);
INSERT INTO rel_refunds VALUES (700, 70), (701, 70);`)
	t.Cleanup(func() { run(t, e, def, "setup", "DROP TABLE IF EXISTS rel_refunds, rel_orders, rel_customers") })
	if res := Introspect(IntrospectRequest{DataSourceID: def.ID, Refresh: true}); res.Error != nil {
		t.Fatal(res.Error)
	}
	orders := OpenTable(OpenTableRequest{ExecID: "o", ConsoleID: "browse", DataSourceID: def.ID, Schema: "public", Table: "rel_orders", PageSize: 500})
	if orders.Error != nil || len(orders.ForeignKeyColumns) != 1 || len(orders.ReferencingTables) != 1 {
		t.Fatalf("open = %+v", orders)
	}
	rid := orders.Statements[0].ResultID
	ref := RelatedRows(RelatedRowsRequest{ResultID: rid, Row: 0, Column: orders.ForeignKeyColumns[0], Direction: RelatedReferenced})
	if ref.Error != nil || len(ref.Targets) != 1 || ref.Targets[0].Table != "rel_customers" || ref.Targets[0].Where != `"id" = 7` {
		t.Fatalf("referenced = %+v", ref)
	}
	back := RelatedRows(RelatedRowsRequest{ResultID: rid, Row: 0, Direction: RelatedReferencing})
	if back.Error != nil || len(back.Targets) != 1 || back.Targets[0].Where != `"order_id" = 70` {
		t.Fatalf("referencing = %+v", back)
	}
	refunds := OpenTable(OpenTableRequest{ExecID: "r", ConsoleID: "browse", DataSourceID: def.ID, Schema: "public", Table: "rel_refunds", Where: back.Targets[0].Where, PageSize: 500})
	if refunds.Error != nil || refunds.Statements[0].RowsFetched != 2 {
		t.Fatalf("refunds = %+v", refunds.Statements)
	}
}
