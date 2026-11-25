#!/bin/bash
# Database journey: add a SQLite data source, test it, run and page through a 1,000,000-row result, Fetch All and Stop,
# sort, the cell viewer, the DELETE confirmation, a read-only refusal, the schema outline, completion, Stop on a long query
# and closing a console with an open transaction. Then the table editor (filter, edit two cells, add and delete a row,
# preview and submit, Manual mode and Roll Back), Explain Plan, bound parameters, an error underline, the query history
# finder, Command-click on a table name, an export of the 1,000,000-row result to CSV and data source detection. The
# PostgreSQL leg runs when GOLENS_TEST_PG_DSN is set and adds Explain Analyze of a DELETE that rolls back and
# Command-click on a schema-qualified table name, then the Go integration: Run SQL lenses on a database/sql and a pgx
# call with a bound parameter, completion inside a backquoted SQL string, Run Query on a sqlc query with sqlc.arg,
# Show Referenced Row and Show Referencing Rows, and (in the short-panel launch) the SSH section of the data source sheet. An SSH leg runs when
# GOLENS_TEST_SSH_DEST is set (GOLENS_TEST_SSH_DB_HOST and GOLENS_TEST_SSH_DB_PORT name the database as the SSH host sees it).
# Usage: scripts/smoke/database-journey.sh [path/to/GoLensApp] [--keep]
# DATABASE_JOURNEY_PERF_ONLY=1 stops after the budget steps (first rows, paging, Fetch All, full scroll).
# DATABASE_JOURNEY_GO_ONLY=1 (with GOLENS_TEST_PG_DSN) runs only the Go integration, related rows and SSH steps and their checks.
# DATABASE_JOURNEY_EDITOR_ONLY=1 skips from the first page to the table editor steps (for working on them);
# with DATABASE_JOURNEY_KEEP_CURSOR=1 the 1,000,000-row result stays open on the SQLite file while the table edits are submitted.
set -u
export GOPILOT_CREDENTIAL_STORE=file
export GOLENS_UNSAVED_RECOVERY=off
export GOLENS_VM_MEMORY_MB=512
export GOLENS_MEASURE=1
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=$REPO/.build/release/GoLensApp
KEEP=0
for a in "$@"; do case $a in --keep) KEEP=1 ;; *) BIN=$a ;; esac; done
[ -x "$BIN" ] || { echo "missing binary: $BIN (run make build)"; exit 2; }
command -v sqlite3 >/dev/null || { echo "sqlite3 is required to build the fixture"; exit 2; }

DOMAIN=dev.golens.test.database
WORK=$(cd "$(mktemp -d -t golens-database)" && pwd -P)
ART=${DATABASE_JOURNEY_ARTIFACTS:-$(cd "$(mktemp -d -t golens-database-artifacts)" && pwd -P)}
mkdir -p "$ART/shots" "$ART/logs"
RESULTS=$ART/results.tsv
: > "$RESULTS"
START=$(date +%s)
APP_PID=

cleanup() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null
    for _ in 1 2 3 4 5; do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.4; done
    kill -KILL "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
  fi
  APP_PID=
  defaults delete $DOMAIN >/dev/null 2>&1
  rm -rf "$HOME/Library/Application Support/$DOMAIN/QueryHistory"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/app/GoLens.app" >/dev/null 2>&1 || true
  [ $KEEP = 1 ] && echo "kept fixtures: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

BUNDLE_ID=$DOMAIN "$REPO/scripts/bundle-app.sh" "$BIN" "$WORK/app" >/dev/null 2>&1 || { echo "bundle-app.sh failed"; exit 2; }
APP=$WORK/app/GoLens.app/Contents/MacOS/$(basename "$BIN")
clang -dynamiclib -fobjc-arc -framework AppKit -framework CoreImage -o "$WORK/driver.dylib" "$HERE/driver.m" 2>/dev/null || { echo "driver build failed"; exit 2; }
clang -dynamiclib -fobjc-arc -framework AppKit -o "$WORK/quiet.dylib" "$HERE/quiet-launch.m" 2>/dev/null || { echo "quiet-launch build failed"; exit 2; }
xattr -cr "$WORK/driver.dylib" "$WORK/quiet.dylib" 2>/dev/null || true
codesign --force --sign - "$WORK/driver.dylib" "$WORK/quiet.dylib" >/dev/null 2>&1 || true
INJECT="$WORK/quiet.dylib:$WORK/driver.dylib"
defaults delete $DOMAIN >/dev/null 2>&1

P=$WORK/dbshop
mkdir -p "$P/.golens"
sqlite3 "$P/orders.db" < "$HERE/db-fixture/orders.sql" || { echo "fixture database build failed"; exit 2; }
cp "$HERE/db-fixture/console.sql" "$HERE/db-fixture/reports.sql" "$P/"
printf 'SELECT * FROM orders;\n' > "$P/q1.sql"
printf 'SELECT * FROM orders;\n' > "$P/q2.sql"
printf '# dbshop\n' > "$P/README.md"
cat > "$P/compose.yaml" <<'YAML'
services:
  db:
    image: postgres:17
    ports:
      - "54320:5432"
    environment:
      POSTGRES_USER: shop
      POSTGRES_PASSWORD: devpass
      POSTGRES_DB: shop
YAML

PG_ON=0
PG_PASSWORD=
PG_SOURCE=
if [ -n "${GOLENS_TEST_PG_DSN:-}" ]; then
  PG_ON=1
  read -r PG_USER PG_PASSWORD PG_HOST PG_PORT PG_DB < <(python3 -I -c 'import sys, urllib.parse as u; d = u.urlparse(sys.argv[1]); print(u.unquote(d.username or ""), u.unquote(d.password or "") or "-", d.hostname or "localhost", d.port or 5432, (d.path or "/").lstrip("/") or "postgres")' "$GOLENS_TEST_PG_DSN")
  [ "$PG_PASSWORD" = - ] && PG_PASSWORD=
  PG_MODE=$([ -n "$PG_PASSWORD" ] && echo ask || echo none)
  PG_SOURCE=$(printf ',{"id":"journey-postgres","name":"Postgres","engine":"postgres","host":"%s","port":%s,"database":"%s","user":"%s","password":"%s","ssl":{"mode":"disable","rootCert":"","cert":"","key":""},"sqlitePath":"","sqliteCreate":false,"defaultSchema":"public","readOnly":false,"production":false}' "$PG_HOST" "$PG_PORT" "$PG_DB" "$PG_USER" "$PG_MODE")
  printf 'SELECT g AS n, md5(g::text) AS hash, now() AS at FROM generate_series(1, 100000) AS g;\n\nCREATE TABLE IF NOT EXISTS golens_journey_items (id int PRIMARY KEY, name text);\n\nINSERT INTO golens_journey_items VALUES (1, %s), (2, %s), (3, %s) ON CONFLICT DO NOTHING;\n\nDELETE FROM golens_journey_items WHERE id = 1;\n\nSELECT count(*) AS item_count FROM public.golens_journey_items;\n' "'a'" "'b'" "'c'" > "$P/postgres.sql"
  printf '\nCREATE TABLE IF NOT EXISTS golens_journey_orders (id int PRIMARY KEY, item_id int REFERENCES golens_journey_items(id));\n\nINSERT INTO golens_journey_orders VALUES (10, 2), (11, 2) ON CONFLICT DO NOTHING;\n\nSELECT * FROM golens_journey_orders;\n' >> "$P/postgres.sql"
  mkdir -p "$P/store" "$P/sqlc/queries"
  cat > "$P/store/store.go" <<'GO'
package store

import (
	"context"
	"database/sql"

	"github.com/jackc/pgx/v5"
)

type Store struct {
	db   *sql.DB
	conn *pgx.Conn
}

type Index struct{}

func (Index) Query(q string) []string { return nil }

func (s *Store) Item(ctx context.Context, id int) *sql.Row {
	return s.db.QueryRowContext(ctx, `
		SELECT id, name FROM golens_journey_items gji
		WHERE gji.id = $1`, id)
}

func (s *Store) Names(ctx context.Context) (pgx.Rows, error) {
	return s.conn.Query(ctx, "SELECT name FROM golens_journey_items ORDER BY id")
}

func (s *Store) Search(ix Index) []string {
	return ix.Query("SELECT not a database call")
}
GO
  printf 'version: "2"\nsql:\n  - engine: "postgresql"\n    schema: "schema.sql"\n    queries: "queries"\n    gen:\n      go:\n        package: "db"\n        out: "db"\n' > "$P/sqlc/sqlc.yaml"
  printf -- '-- name: GetItem :one\nSELECT id, name FROM golens_journey_items WHERE id = sqlc.arg(id);\n' > "$P/sqlc/queries/items.sql"
  if [ -n "${GOLENS_TEST_SSH_DEST:-}" ]; then
    PG_SOURCE=$(printf '%s,{"id":"journey-postgres-ssh","name":"Postgres via SSH","engine":"postgres","host":"%s","port":%s,"database":"%s","user":"%s","password":"%s","ssl":{"mode":"disable","rootCert":"","cert":"","key":""},"sqlitePath":"","sqliteCreate":false,"defaultSchema":"public","readOnly":true,"production":false,"ssh":{"destination":"%s","port":0}}' "$PG_SOURCE" "${GOLENS_TEST_SSH_DB_HOST:-127.0.0.1}" "${GOLENS_TEST_SSH_DB_PORT:-$PG_PORT}" "$PG_DB" "$PG_USER" "$PG_MODE" "$GOLENS_TEST_SSH_DEST")
    printf 'SELECT 41 + 1 AS through_ssh;\n' > "$P/ssh.sql"
  fi
fi
BASTION=
[ $PG_ON = 1 ] && BASTION='{"id":"journey-bastion","name":"Bastion","engine":"postgres","host":"db.internal","port":5432,"database":"shop","user":"shop","password":"ask","ssl":{"mode":"prefer","rootCert":"","cert":"","key":""},"sqlitePath":"","sqliteCreate":false,"defaultSchema":"public","readOnly":true,"production":false,"ssh":{"destination":"deploy@bastion.example.com","port":2222}}'
printf '{"version":1,"dataSources":[{"id":"journey-reports","name":"Reports","engine":"sqlite","host":"","port":0,"database":"","user":"","password":"none","ssl":{"mode":"disable","rootCert":"","cert":"","key":""},"sqlitePath":"orders.db","sqliteCreate":false,"defaultSchema":"main","readOnly":true,"production":false}%s]}\n' "$PG_SOURCE" > "$P/.golens/data-sources.json"

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }
check() { if eval "$3"; then record "$1" "$2" PASS "$4"; else record "$1" "$2" FAIL "$4"; fi; }
both() { printf 'shot:light-%s;darkmode;wait:0.8;shot:dark-%s;lightmode;wait:0.6;' "$1" "$1"; }
bothsheet() { printf 'sheetshot:light-%s;darkmode;wait:0.8;sheetshot:dark-%s;lightmode;wait:0.6;' "$1" "$1"; }
run() { printf 'menu:Tools/Database/Run Statement;'; }

LOG=$ART/logs/journey.log
APPLOG=$ART/logs/app.log
WIN=dbshop
T="wait:10;fakeactive;mark:ready;"
T="${T}menu:Tools/Database/Data Sources…;wait:1.5;axpress:Add Data Source;wait:1;field:0:Local;axpress:SQLite;wait:0.8;field:1:orders.db;wait:0.4;"
T="${T}axpress:Test Connection;waitlabel:Connected · ;deeplabels;$(bothsheet 01-data-source-tested)axpress:Done;wait:1.2;mark:added;"
T="${T}menu:Tools/Database/Attach Console To/Local;wait:0.6;caret:SELECT * FROM orders;$(run)waitlabel:500 rows loaded;mark:first-rows;wait:1;"
if [ "${DATABASE_JOURNEY_EDITOR_ONLY:-0}" != 1 ]; then
for i in $(seq 1 20); do T="${T}caret:SELECT * FROM orders;$(run)wait:0.6;"; done
T="${T}waitlabel:500 rows loaded;$(both 02-first-page)"
T="${T}hangmon:on;mark:scroll-start;"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do T="${T}winwheel:$WIN|-1600;"; done
T="${T}hangmon:report;mark:scroll-done;deeplabels;"
T="${T}rowmenu:status, paid|Sort Descending;wait:1.5;waitlabel:Sorted loaded rows only;mark:sorted;$(both 03-sorted-loaded)"
T="${T}wait:3;mark:fetch-start;waitfile:$WORK/fetch-base-done;axpress:Fetch All;waitlabel:1,000,000 rows ;mark:fetched-all;wait:1.5;deeplabels;mark:fetch-settled;$(both 04-fetched-all)"
T="${T}rowmenu:currency, EUR|Clear Sort;wait:1.5;hangmon:on;mark:full-scroll-start;"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do T="${T}winwheel:$WIN|-1600;"; done
for i in 1 2 3 4 5 6; do T="${T}winwheel:$WIN|1600;"; done
T="${T}hangmon:report;mark:full-scroll-done;waitfile:$WORK/full-scroll-foot-done;axpress:Close Result;mark:result-closed;waitfile:$WORK/close-footprint-done;"
T="${T}mark:db8b-before;waitfile:$WORK/db8b-before-done;"
T="${T}rowdblclick:q1.sql;wait:1.5;menu:Tools/Database/Attach Console To/Local;wait:0.6;caret:SELECT * FROM orders;$(run)waitlabel:500 rows loaded;axpress:Fetch All;waitlabel:1,000,000 rows ;mark:db8b-q1-fetched;"
T="${T}rowdblclick:q2.sql;wait:1.5;menu:Tools/Database/Attach Console To/Local;wait:0.6;caret:SELECT * FROM orders;$(run)waitlabel:500 rows loaded;axpress:Fetch All;waitlabel:1,000,000 rows ;mark:db8b-q2-fetched;waitfile:$WORK/db8b-peak-done;"
T="${T}rowdblclick:console.sql;wait:1.5;rowmenu:Close console.sql|Close Other Tabs;wait:1.5;axexists:Close q1.sql;axexists:Close q2.sql;axexists:Close console.sql;mark:db8b-closed;waitfile:$WORK/db8b-after-done;"
[ "${DATABASE_JOURNEY_PERF_ONLY:-0}" = 1 ] && T="${T}mark:done;quit;"
T="${T}caret:SELECT * FROM orders;$(run)waitlabel:500 rows loaded;rowdblclick:currency, EUR;wait:1.2;popoverlabels;mark:cell-viewer;$(both 05-cell-viewer)key:cancelOperation:;wait:0.4;"
T="${T}caret:SELECT o.id;$(run)waitlabel:500 rows loaded;axpress:Fetch All;wait:1;axpress:Stop;wait:1.5;mark:fetch-stopped;deeplabels;"
T="${T}caret:DELETE FROM orders;$(run)wait:1.5;wininfo;$(bothsheet 06-delete-confirm)sheetpress:Cancel;wait:1;mark:delete-canceled;"
T="${T}caret:SELECT count(*) AS order_count;$(run)wait:2;axfind:order_count, ;mark:counted;"
T="${T}caret:WITH RECURSIVE r;$(run)wait:1.5;mark:long-running;menu:Tools/Database/Stop Statement;waitlabel:Canceled;mark:long-stopped;$(both 07-canceled)"
T="${T}caret:SELECT o.c;type:ustomer_i;wait:1.5;panel;mark:completion;$(both 08-completion)key:cancelOperation:;wait:0.3;undo;undo;wait:0.3;text;"
T="${T}rowdblclick:reports.sql;wait:2;menu:Tools/Database/Attach Console To/Reports;wait:0.6;caret:UPDATE orders;$(run)waitlabel:Read-Only Data Source;mark:read-only;$(both 09-read-only)"
T="${T}rowexpand:Local;wait:1.5;rowexpand:main;wait:1.5;rowexpand:Tables;wait:1.5;axfind:orders;axfind:customers;mark:outline;$(both 10-schema-outline)"
T="${T}rowdblclick:console.sql;wait:2;caret:BEGIN;$(run)wait:1.5;caret:INSERT INTO notes;$(run)wait:1.5;waitlabel:Transaction Active;mark:transaction;"
T="${T}rowdblclick:reports.sql;wait:1.5;rowmenu:Close reports.sql|Close Other Tabs;wait:1.5;wininfo;$(bothsheet 11-close-others-transaction)sheetpress:Cancel;wait:1;axexists:Close console.sql;mark:close-others-canceled;"
T="${T}menu:File/Close Tab;wait:1.5;wininfo;sheetpress:Roll Back;wait:2;wininfo;axexists:Close console.sql;mark:closed-rolled-back;"
else
  [ "${DATABASE_JOURNEY_KEEP_CURSOR:-0}" = 1 ] || T="${T}caret:SELECT count(*) AS order_count;$(run)wait:2;"
  T="${T}rowdblclick:reports.sql;wait:2;rowexpand:Local;wait:3;rowexpand:main;wait:2;rowexpand:Tables;wait:2;"
fi
T="${T}rowdblclick:customers;waitlabel:Count Rows;mark:table-open;"
T="${T}fieldp:Filter, for example status = 'paid':country = 'VN';wait:3;fieldp:Column, for example created_at DESC:id DESC;wait:3;waitlabel:Count Rows;axpress:Count Rows;waitlabel:1,253 rows match the filter;mark:filtered;"
T="${T}rowclick:name, Customer 5002;postkey:36;wait:0.8;fieldp:name:Edited First;wait:0.6;"
T="${T}rowclick:name, Customer 5001;postkey:36;wait:0.8;fieldp:name:Edited Second;wait:0.6;"
T="${T}rowmenu:name, Customer 5003|Delete Rows;wait:0.8;"
T="${T}rowmenu:name, Edited First|Add Row;wait:1;focus;mark:added-row;"
T="${T}rowclick:email, default;postkey:36;wait:0.8;focus;fieldp:email:journey.new@example.com;wait:0.6;"
T="${T}rowclick:name, default;postkey:36;wait:0.8;postkey:53;wait:0.6;mark:escaped;rowclick:country, default;postkey:36;wait:0.8;focus;fieldp:country:VN;wait:0.6;"
T="${T}rowclick:name, default;postkey:36;wait:0.8;focus;fieldp:name:Journey New;wait:0.6;"
T="${T}wait:0.5;deeplabels;mark:edited;$(both 13-table-edits)"
T="${T}menu:Tools/Database/Submit Changes;wait:1.5;waitlabel:4 statements run;labels;mark:preview;$(bothsheet 14-submit-preview)"
T="${T}axpress:Submit 4 Statements;wait:2;sheetshot:light-14b-after-submit;shot:light-14c-after-submit;deeplabels;waitlabel:Changes Submitted;waitlabel:Count Rows;axfind:name, Edited First;axfind:name, Journey New;mark:submitted;"
T="${T}rowdblclick:README.md;wait:1.5;menu:Tools/Database/Transaction Mode/Manual;wait:1.5;mark:switched;rowclick:name, Journey New;postkey:36;wait:0.8;focus;fieldp:name:Manual New;wait:0.6;"
T="${T}menu:Tools/Database/Submit Changes;wait:1.5;waitlabel:Manual Transaction;axpress:Submit 1 Statement;wait:1.5;waitlabel:Changes Not Committed Yet;waitlabel:Transaction Active;mark:manual-applied;$(both 15-manual-transaction)"
T="${T}gridgeom:Rows of customers;waitfile:$P/orders.db-journal;wait:2;axfind:orders.db-journal;axfind:compose.yaml;mark:journal-hidden;"
T="${T}axpress:Roll Back;wait:2;waitlabel:Count Rows;axfind:name, Journey New;mark:rolled-back;"
T="${T}menu:Tools/Database/Transaction Mode/Auto-Commit;wait:1;"
T="${T}rowdblclick:console.sql;wait:2;caret:CROSS JOIN customers c;menu:Tools/Database/Explain Plan;waitlabel:Explain Plan · ;deeplabels;mark:explained;$(both 16-explain)"
T="${T}caret:WHERE name = :name;$(run)wait:1.5;waitlabel:Query Parameters;field:0:'\\x3b DROP TABLE t\\x3b --;$(bothsheet 17-parameters)axpress:Run with These Values;wait:2.5;deeplabels;mark:bound;"
T="${T}caret:SELECT * FROMM orders;$(run)waitlabel:Statement Failed;wait:0.8;underline:FROMM;mark:error-underline;$(both 18-error-underline)"
T="${T}caret:SELECT * FROMM orders;menu:Tools/Database/Query History…;wait:1.5;labels;$(both 19-query-history)fieldp:Search Query History of “Local”:order_count;wait:1.5;text;mark:history-inserted;undo;wait:0.5;"
T="${T}caret:SELECT * FROM orders;cmdhover:order_count;cmdhover:orders;wait:0.3;mark:table-link;$(both 23-table-link)cmdclick:orders;wait:2;waitlabel:Count Rows;axfind:Rows of orders;mark:table-link-opened;"
T="${T}caret:SELECT * FROM orders;$(run)waitlabel:500 rows loaded;mark:export-start;menu:Tools/Database/Export Result…;wait:1.5;waitlabel:Export Result;firstlinegap:Copy generated code|Export preview;$(bothsheet 20-export)"
T="${T}stubpanel:$P/result.csv;axpress:Choose the Export File;wait:2;waitlabel:Result Exported;gridgeom:Results;mark:exported;waitfile:$WORK/export-footprint-done;"
T="${T}menu:Tools/Database/Detect Data Sources in Project…;wait:2;waitlabel:compose.yaml;deeplabels;mark:detected;$(bothsheet 21-detect)axpresslast:Cancel;wait:1;"
if [ $PG_ON = 1 ]; then
  T="${T}rowclick:postgres.sql;wait:2;menu:Tools/Database/Attach Console To/Postgres;wait:0.6;caret:SELECT g;$(run)wait:2;"
  [ -n "$PG_PASSWORD" ] && T="${T}field:0:$PG_PASSWORD;sheetpress:Connect;"
  T="${T}waitlabel:500 rows loaded;mark:pg-first-rows;$(both 12-postgres)"
  T="${T}caret:CREATE TABLE IF NOT EXISTS;$(run)wait:2;caret:ON CONFLICT DO NOTHING;$(run)wait:2;"
  T="${T}caret:DELETE FROM golens_journey_items WHERE id = 1;menu:Tools/Database/Explain Analyze;waitlabel:Changes Rolled Back;mark:pg-analyzed;$(both 22-postgres-explain-analyze)"
  T="${T}caret:AS item_count;$(run)wait:2;axfind:item_count, 3;mark:pg-counted;"
  T="${T}cmdhover:public.golens_journey_items;wait:0.3;$(both 24-postgres-table-link)cmdclick:golens_journey_items;wait:2;waitlabel:Count Rows;axfind:Rows of golens_journey_items;mark:pg-table-link;"
  G=""
  G="${G}caret:CREATE TABLE IF NOT EXISTS golens_journey_orders;$(run)wait:2;caret:INSERT INTO golens_journey_orders;$(run)wait:2;caret:SELECT * FROM golens_journey_orders;$(run)wait:3;"
  G="${G}cmdclick:golens_journey_orders;wait:2.5;waitlabel:Count Rows;axfind:Rows of golens_journey_orders;mark:pg-orders-open;"
  G="${G}rowmenu:item_id, 2|Show Referenced Row;wait:2.5;waitlabel:Count Rows;axfind:Rows of golens_journey_items;axfind:name, b;axfind:name, c;mark:referenced;$(both 28-referenced-row)"
  G="${G}rowmenu:name, b|Show Referencing Rows/golens_journey_orders (item_id);wait:2.5;waitlabel:Count Rows;axfind:Rows of golens_journey_orders;axfind:id, 10;axfind:id, 11;mark:referencing;$(both 29-referencing-rows)"
  G="${G}menu:Tools/Database/Default Data Source/Postgres;wait:0.8;rowexpand:store;wait:1;rowdblclick:store.go;wait:5;mark:go-open;$(both 25-run-sql-lens)"
  G="${G}lensclick:QueryRowContext(ctx|Run SQL|0;wait:1.5;waitlabel:Query Parameters;field:0:2;axpress:Run with These Values;wait:2.5;waitlabel:store.go:;axfind:name, b;mark:go-sql-ran;$(both 26-go-sql-result)"
  G="${G}lensclick:s.conn.Query(ctx|Run SQL|0;waitlabel:store.go:26;wait:1;axfind:name, c;mark:pgx-sql-ran;"
  G="${G}caret:WHERE gji.;type:n;wait:1.5;panel;mark:go-completion;$(both 27-go-sql-completion)key:cancelOperation:;wait:0.3;undo;wait:0.3;"
  G="${G}caret:SELECT not a;type:x;wait:1.5;panel;mark:go-plain-string;key:cancelOperation:;wait:0.3;undo;wait:0.3;"
  G="${G}rowexpand:sqlc;wait:1;rowexpand:queries;wait:1;rowdblclick:items.sql;wait:4;mark:sqlc-open;$(both 30-sqlc-run-query)"
  G="${G}caret:-- name: GetItem;menu:Tools/Database/Run Query;wait:1.5;waitlabel:Query Parameters;field:0:3;axpress:Run with These Values;wait:2.5;axfind:name, c;mark:sqlc-ran;"
  if [ -n "${GOLENS_TEST_SSH_DEST:-}" ]; then
    G="${G}rowclick:ssh.sql;wait:2;menu:Tools/Database/Attach Console To/Postgres via SSH;wait:0.6;caret:SELECT 41;$(run)wait:2;"
    [ -n "$PG_PASSWORD" ] && G="${G}field:0:$PG_PASSWORD;sheetpress:Connect;"
    G="${G}wait:6;axfind:through_ssh, 42;mark:ssh-ran;waitfile:$WORK/ssh-seen;"
  fi
  if [ "${DATABASE_JOURNEY_GO_ONLY:-0}" = 1 ]; then
    T="wait:10;fakeactive;mark:ready;rowclick:postgres.sql;wait:2;menu:Tools/Database/Attach Console To/Postgres;wait:0.6;caret:SELECT g;$(run)wait:2;"
    [ -n "$PG_PASSWORD" ] && T="${T}field:0:$PG_PASSWORD;sheetpress:Connect;"
    T="${T}waitlabel:500 rows loaded;caret:CREATE TABLE IF NOT EXISTS;$(run)wait:2;caret:ON CONFLICT DO NOTHING;$(run)wait:2;"
  fi
  T="${T}${G}"
fi
T="${T}mark:done;quit"

DRIVE="$T" DRIVE_OUT=$LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$INJECT" \
  "$APP" -AppleInterfaceStyle Light -GoLensLastWorkspacePath "$P" -GoLensLastFilePath "$P/console.sql" -GoLensShowConsole '<true/>' -GoLensEnablePreviewTab '<false/>' > "$APPLOG" 2>&1 &
APP_PID=$!

FOOT_BEFORE=
FOOT_PEAK=0
FOOT_FETCHED=
FOOT_CLOSED=
CLOSED_AT=
DB8B_BEFORE=
DB8B_PEAK=
DB8B_AFTER=
DB8B_CLOSED_AT=
EXPORT_BASE=
EXPORT_PEAK=0
mb() { awk '{v=$1; u=$2; if (u ~ /^K/) v/=1024; else if (u ~ /^G/) v*=1024; else if (u ~ /^B/) v/=1048576; printf "%.0f", v}'; }
foot() { footprint -p "$APP_PID" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}' | mb; }
inwin() { grep -q "DRIVE mark $1\$" "$LOG" 2>/dev/null && ! grep -q "DRIVE mark $2\$" "$LOG" 2>/dev/null; }
i=0
while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt 4800 ]; do
  if [ ! -e "$WORK/export-footprint-done" ] && grep -q "DRIVE mark export-start" "$LOG" 2>/dev/null; then
    NOW=$(footprint -p "$APP_PID" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}' | mb)
    [ -z "$EXPORT_BASE" ] && EXPORT_BASE=$NOW
    [ -n "$NOW" ] && [ "$NOW" -gt "$EXPORT_PEAK" ] && EXPORT_PEAK=$NOW
    grep -q "DRIVE mark exported" "$LOG" 2>/dev/null && touch "$WORK/export-footprint-done"
  fi
  if [ -z "$FOOT_BEFORE" ] && grep -q "DRIVE mark fetch-start" "$LOG" 2>/dev/null; then
    FOOT_BEFORE=$(foot)
    touch "$WORK/fetch-base-done"
  elif [ -n "$FOOT_BEFORE" ] && [ -z "$CLOSED_AT" ]; then
    if inwin fetch-start fetch-settled; then
      NOW=$(foot)
      if inwin fetch-start fetch-settled; then
        [ -n "$NOW" ] && [ "$NOW" -gt "$FOOT_PEAK" ] && FOOT_PEAK=$NOW
        [ -z "$FOOT_FETCHED" ] && grep -q "DRIVE mark fetched-all" "$LOG" 2>/dev/null && FOOT_FETCHED=$NOW
      fi
    elif [ ! -e "$WORK/full-scroll-foot-done" ] && grep -q "DRIVE mark full-scroll-done" "$LOG" 2>/dev/null; then
      NOW=$(foot)
      [ -n "$NOW" ] && [ "$NOW" -gt "$FOOT_PEAK" ] && FOOT_PEAK=$NOW
      touch "$WORK/full-scroll-foot-done"
    fi
    grep -q "DRIVE mark result-closed" "$LOG" 2>/dev/null && CLOSED_AT=$(date +%s)
  elif [ -n "$CLOSED_AT" ] && [ -z "$FOOT_CLOSED" ] && [ $(( $(date +%s) - CLOSED_AT )) -ge 10 ]; then
    FOOT_CLOSED=$(foot)
    touch "$WORK/close-footprint-done"
  fi
  if [ -z "$DB8B_BEFORE" ] && grep -q "DRIVE mark db8b-before" "$LOG" 2>/dev/null; then
    DB8B_BEFORE=$(foot)
    touch "$WORK/db8b-before-done"
  elif [ -z "$DB8B_PEAK" ] && grep -q "DRIVE mark db8b-q2-fetched" "$LOG" 2>/dev/null; then
    DB8B_PEAK=$(foot)
    touch "$WORK/db8b-peak-done"
  elif [ -z "$DB8B_CLOSED_AT" ] && grep -q "DRIVE mark db8b-closed" "$LOG" 2>/dev/null; then
    DB8B_CLOSED_AT=$(date +%s)
  elif [ -n "$DB8B_CLOSED_AT" ] && [ -z "$DB8B_AFTER" ] && [ $(( $(date +%s) - DB8B_CLOSED_AT )) -ge 12 ]; then
    DB8B_AFTER=$(foot)
    touch "$WORK/db8b-after-done"
  fi
  if [ ! -e "$WORK/ssh-seen" ] && grep -q "DRIVE mark ssh-ran" "$LOG" 2>/dev/null; then
    pgrep -f "ssh -N -L 127.0.0.1:.* -o ExitOnForwardFailure=yes" > "$WORK/ssh-pids" 2>/dev/null
    touch "$WORK/ssh-seen"
  fi
  sleep 0.25
  i=$((i + 1))
done
if kill -0 "$APP_PID" 2>/dev/null; then
  kill -TERM "$APP_PID" 2>/dev/null; sleep 1; kill -KILL "$APP_PID" 2>/dev/null
fi
wait "$APP_PID" 2>/dev/null
APP_PID=
sleep 1
SSH_LEFT=$(pgrep -f "ssh -N -L 127.0.0.1:.* -o ExitOnForwardFailure=yes" | tr "\n" " ")

SHORT_LOG=$ART/logs/short-panel.log
SHORT_HEIGHT=140
if [ "${DATABASE_JOURNEY_PERF_ONLY:-0}" != 1 ]; then
  [ -n "$BASTION" ] && python3 -I -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["dataSources"].insert(0, json.loads(sys.argv[2])); json.dump(d, open(p, "w"))' "$P/.golens/data-sources.json" "$BASTION"
  T="wait:10;fakeactive;mark:short-ready;menu:Tools/Database/Attach Console To/Local;wait:0.6;caret:SELECT count(*) AS order_count;$(run)wait:3;"
  T="${T}menu:Tools/Database/Export Result…;wait:1.5;waitlabel:Export Result;stubpanel:$P/short-panel.csv;axpress:Choose the Export File;wait:3;gridgeom:Results;$(both 15b-short-panel)"
  [ -n "$BASTION" ] && T="${T}rowmenu:Bastion|Edit Data Source…;wait:1.5;fieldp:user@bastion or a Host alias:deploy@bastion.example.com;wait:0.8;deeplabels;mark:ssh-section;$(bothsheet 31-ssh-section)axpresslast:Cancel;wait:1;"
  T="${T}mark:short-done;quit"
  DRIVE="$T" DRIVE_OUT=$SHORT_LOG DRIVE_SHOTS=$ART/shots DYLD_INSERT_LIBRARIES="$INJECT" \
    "$APP" -AppleInterfaceStyle Light -GoLensLastWorkspacePath "$P" -GoLensLastFilePath "$P/console.sql" -GoLensShowConsole '<true/>' -GoLensEnablePreviewTab '<false/>' -GoLensConsoleHeight $SHORT_HEIGHT > "$ART/logs/short-panel-app.log" 2>&1 &
  APP_PID=$!
  i=0
  while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt 600 ]; do sleep 0.25; i=$((i + 1)); done
  if kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null; sleep 1; kill -KILL "$APP_PID" 2>/dev/null
  fi
  wait "$APP_PID" 2>/dev/null
  APP_PID=
fi

has() { grep -q -- "$1" "$LOG"; }
after() { sed -n "/DRIVE mark $1\$/,\$p" "$LOG"; }
between() { sed -n "/DRIVE mark $1\$/,/DRIVE mark $2\$/p" "$LOG"; }

check DB1 "Data Sources adds a SQLite data source and Test Connection reports the server" 'has "waitlabel .Connected · . -> 1"' "shots/light-01-data-source-tested.png, shots/dark-01-data-source-tested.png"
check DB2 "The new data source is saved without a host, user or port" 'python3 -I -c "import json,sys; d=[s for s in json.load(open(sys.argv[1]))[\"dataSources\"] if s[\"name\"]==\"Local\"][0]; sys.exit(0 if d[\"engine\"]==\"sqlite\" and not d[\"host\"] and not d[\"user\"] and d[\"port\"]==0 else 1)" "$P/.golens/data-sources.json" 2>/dev/null' ".golens/data-sources.json"
check DB3 "Run Statement shows the first 500 rows of SELECT * FROM orders" 'has "waitlabel .500 rows loaded. -> 1"' "shots/light-02-first-page.png, shots/dark-02-first-page.png"
SCROLL=$(between scroll-start scroll-done | grep -m1 "hangmon report")
FULL=$(between full-scroll-start full-scroll-done | grep -m1 "hangmon report")
FULL_MAX=$(echo "$FULL" | sed -E 's/.*max=([0-9.]+).*/\1/')
check DB4 "Scrolling the full 1,000,000-row result has no main-thread stall over 16 ms" 'between full-scroll-start full-scroll-done | grep -q "winwheel.*afterY" && [ -n "$FULL_MAX" ] && awk "BEGIN{exit !($FULL_MAX <= 16.0)}"' "full result: $FULL; while paging: $SCROLL"
LOADED=$(between scroll-done sorted | grep -m1 deeplabels | grep -oE "[0-9,]+ rows loaded" | head -1)
check DB5 "Paging reads further rows from the open cursor" '[ -n "$LOADED" ] && [ "$LOADED" != "500 rows loaded" ]' "$LOADED"
check DB6 "Sorting a partial result says it sorted the loaded rows only" 'has "waitlabel .Sorted loaded rows only. -> 1"' "shots/light-03-sorted-loaded.png"
FETCH_GROWTH=$(( ${FOOT_PEAK:-0} - ${FOOT_BEFORE:-0} ))
CLOSE_DELTA=$(( ${FOOT_CLOSED:-0} - ${FOOT_BEFORE:-0} ))
check DB8 "Fetch All reads all 1,000,000 rows within 120 MB peak footprint growth, and 10 s after Close Result the footprint is within 10 MB of where it started" 'has "waitlabel .1,000,000 rows . -> 1" && [ -n "$FOOT_BEFORE" ] && [ -n "$FOOT_FETCHED" ] && [ "$FOOT_PEAK" -gt 0 ] && [ -n "$FOOT_CLOSED" ] && [ "$FETCH_GROWTH" -le 120 ] && [ "$CLOSE_DELTA" -le 10 ]' "footprint before Fetch All ${FOOT_BEFORE} MB, at 1,000,000 rows ${FOOT_FETCHED} MB, peak during Fetch All and the full scroll ${FOOT_PEAK} MB (growth ${FETCH_GROWTH} MB; the screenshots in between are not counted), 10 s after Close Result ${FOOT_CLOSED} MB (${CLOSE_DELTA} MB from the start); shots/light-04-fetched-all.png"
DB8B_DELTA=$(( ${DB8B_AFTER:-0} - ${DB8B_BEFORE:-0} ))
check DB8b "Opening two 1,000,000-row consoles (q1.sql, q2.sql), fetching all rows, selecting console.sql and invoking Close Other Tabs reclaims memory within 10 MB of baseline after 12 s" 'between db8b-before db8b-closed | grep -q "axexists Close q1.sql -> 0" && between db8b-before db8b-closed | grep -q "axexists Close q2.sql -> 0" && between db8b-before db8b-closed | grep -q "axexists Close console.sql -> 1" && [ -n "$DB8B_BEFORE" ] && [ -n "$DB8B_PEAK" ] && [ -n "$DB8B_AFTER" ] && [ "$DB8B_DELTA" -le 10 ]' "before ${DB8B_BEFORE} MB, two 1M-row tabs fetched ${DB8B_PEAK} MB, 12 s after Close Other Tabs ${DB8B_AFTER} MB (delta ${DB8B_DELTA} MB)"
STOPPED=$(after fetch-stopped | grep -m1 deeplabels | grep -oE "[0-9,]+ rows loaded \\| Fetch All" | head -1)
check DB7 "Stop during Fetch All keeps the loaded rows, the result stays partial and Fetch All is offered again" '[ -n "$STOPPED" ]' "$STOPPED"
check DB9 "Double-clicking a cell opens the cell viewer" 'between full-scroll-done cell-viewer | grep -m1 popoverlabels | grep -q "currency"' "shots/light-05-cell-viewer.png"
check DB10 "DELETE without WHERE asks first and Cancel runs nothing" 'between cell-viewer delete-canceled | grep -q "sheetpress Cancel -> 1" && [ "$(sqlite3 "$P/orders.db" "SELECT count(*) FROM orders" 2>/dev/null)" = 1000000 ]' "shots/light-06-delete-confirm.png"
check DB11 "Stop cancels a running statement and the result says Canceled" 'has "waitlabel .Canceled. -> 1"' "shots/light-07-canceled.png"
check DB12 "Completion offers the columns of the table bound to the alias" 'between long-stopped completion | grep -m1 "^DRIVE panel" | grep -q "customer_id"' "shots/light-08-completion.png"
check DB13 "A read-only data source refuses a write" 'has "waitlabel .Read-Only Data Source. -> 1" && [ "$(sqlite3 "$P/orders.db" "SELECT status FROM orders WHERE id = 1" 2>/dev/null)" != void ]' "shots/light-09-read-only.png"
check DB14 "The schema outline lists the tables" 'between read-only outline | grep -q "axfind orders -> [1-9]" && between read-only outline | grep -q "axfind customers -> [1-9]"' "shots/light-10-schema-outline.png"
check DB15 "Close Other Tabs asks about the console with an open transaction and Cancel keeps it open" 'between transaction close-others-canceled | grep -q "Close Console With an Open Transaction" && between transaction close-others-canceled | grep -q "axexists Close console.sql -> 1"' "shots/light-11-close-others-transaction.png"
check DB16 "Closing the console asks, Roll Back closes it and nothing was committed" 'between close-others-canceled closed-rolled-back | grep -q "sheetpress Roll Back -> 1" && between close-others-canceled closed-rolled-back | grep -q "axexists Close console.sql -> 0" && [ "$(sqlite3 "$P/orders.db" "SELECT count(*) FROM notes" 2>/dev/null)" = 0 ]' ""
sq() { sqlite3 "$P/orders.db" "$1" 2>/dev/null; }
check DB21 "A table opens with WHERE and ORDER BY fields, and the filter runs on the server" 'has "DRIVE mark filtered" && has "waitlabel .1,253 rows match the filter. -> 1"' "shots/light-13-table-edits.png"
check DB22 "Edited, new and deleted rows carry a text marker" 'between filtered edited | grep -m1 deeplabels | grep -q "Change, Edited" && between filtered edited | grep -m1 deeplabels | grep -q "Change, New" && between filtered edited | grep -m1 deeplabels | grep -q "Change, Deleted"' "shots/light-13-table-edits.png, shots/dark-13-table-edits.png"
check DB23 "Submit Changes previews four statements before anything is written" 'has "waitlabel .4 statements run. -> 1"' "shots/light-14-submit-preview.png, shots/dark-14-submit-preview.png"
check DB24 "Submitting writes the two edits, the new row and the delete, and the reloaded table shows them" '[ "$(sq "SELECT name FROM customers WHERE id IN (5001, 5002) ORDER BY id")" = "$(printf "Edited Second\nEdited First")" ] && [ "$(sq "SELECT count(*) FROM customers WHERE name = '"'"'Customer 5003'"'"'")" = 0 ] && [ "$(sq "SELECT country FROM customers WHERE email = '"'"'journey.new@example.com'"'"'")" = VN ] && between preview submitted | grep -q "axfind name, Journey New -> [1-9]"' "edits: $(sq "SELECT id, name FROM customers WHERE id >= 5001" | tr "\n" " "); new row: $(sq "SELECT id, country FROM customers WHERE email = 'journey.new@example.com'")"
check DB25 "Manual mode keeps submitted changes in an open transaction and Roll Back restores the row" 'has "waitlabel .Changes Not Committed Yet. -> 1" && has "waitlabel .Transaction Active. -> 1" && [ "$(sq "SELECT name FROM customers WHERE email = '"'"'journey.new@example.com'"'"'")" = "Journey New" ] && between manual-applied rolled-back | grep -q "axfind name, Journey New -> [1-9]"' "shots/light-15-manual-transaction.png, shots/dark-15-manual-transaction.png"
SHORT_GEOM=$(grep -m1 "gridgeom Results" "$SHORT_LOG" 2>/dev/null | cut -c1-220)
check DB36 "With a banner above the grid, the first row sits fully below the header at the default size and in a console panel at its ${SHORT_HEIGHT} pt minimum" 'between manual-applied journal-hidden | grep -q "gridgeom Rows of customers clear=1" && between export-start exported | grep -q "gridgeom Results clear=1" && grep -q "mark short-done" "$SHORT_LOG" 2>/dev/null && echo "$SHORT_GEOM" | grep -q "clear=1"' "default: $(between manual-applied journal-hidden | grep -m1 "gridgeom" | cut -c1-220) | $(between export-start exported | grep -m1 "gridgeom" | cut -c1-220); short panel: ${SHORT_GEOM:-none}; shots/light-15b-short-panel.png, shots/dark-15b-short-panel.png"
check DB37 "SQLite's journal file stays out of the Files tree while a Manual transaction is open" 'between manual-applied journal-hidden | grep -q "waitfile orders.db-journal -> 1" && between manual-applied journal-hidden | grep -q "axfind orders.db-journal -> 0" && between manual-applied journal-hidden | grep -q "axfind compose.yaml -> [1-9]"' "$(between manual-applied journal-hidden | grep -E "waitfile|axfind" | cut -c1-160 | tr "\n" " ")"
check DB38 "The Copy button of the Export preview does not cover the first preview line" 'between export-start exported | grep -q "firstlinegap .* overlap=0"' "$(between export-start exported | grep -m1 "firstlinegap"); shots/light-20-export.png"
check DB26 "Explain Plan on a join shows the plan outline" 'has "waitlabel .Explain Plan · . -> 1"' "shots/light-16-explain.png, shots/dark-16-explain.png"
check DB27 "A parameterized statement asks for its value and binds it: the DROP TABLE text never runs" 'has "waitlabel .Query Parameters. -> 1" && ! between explained bound | grep -m1 "^DRIVE deeplabels" | grep -q "Statement Failed" && [ "$(sq "SELECT count(*) FROM t")" = 1 ]' "shots/light-17-parameters.png, shots/dark-17-parameters.png"
check DB28 "An SQL error position is underlined in the console" 'between bound error-underline | grep -m1 "^DRIVE underline" | grep -qv "red=0"' "$(between bound error-underline | grep -m1 '^DRIVE underline'); shots/light-18-error-underline.png"
HIST=$(between error-underline history-inserted | sed -n '/TEXT<<</,/>>>/p' | grep -c "AS order_count FROM orders")
check DB29 "The query history finder inserts a past statement at the cursor" '[ "$HIST" -ge 2 ]' "occurrences after insert: $HIST; shots/light-19-query-history.png"
EXPORT_LINES=0
[ -f "$P/result.csv" ] && EXPORT_LINES=$(wc -l < "$P/result.csv" 2>/dev/null | tr -d ' ')
EXPORT_GROWTH=$(( ${EXPORT_PEAK:-0} - ${EXPORT_BASE:-0} ))
check DB30 "Export writes the full 1,000,000-row result to CSV while the footprint stays within the Fetch All budget (120 MB growth)" '[ "$EXPORT_LINES" = 1000001 ] && [ -n "$EXPORT_BASE" ] && [ "$EXPORT_GROWTH" -le 120 ]' "lines $EXPORT_LINES; footprint at start ${EXPORT_BASE} MB, peak ${EXPORT_PEAK} MB, growth ${EXPORT_GROWTH} MB; shots/light-20-export.png"
check DB31 "Detection proposes the compose PostgreSQL service and adds nothing on Cancel" 'between exported detected | grep -m1 deeplabels | grep -q "Done adds 1 data source" && between exported detected | grep -m1 deeplabels | grep -q "compose.yaml" && ! grep -q "\"name\":\"db\"" "$P/.golens/data-sources.json"' "shots/light-21-detect.png, shots/dark-21-detect.png"
if [ $PG_ON = 1 ]; then
  check DB32 "PostgreSQL: Explain Analyze of a DELETE says it rolled back and the row stays" 'has "DRIVE mark pg-analyzed" && after pg-analyzed | grep -q "axfind item_count, 3 -> [1-9]"' "shots/light-22-postgres-explain-analyze.png"
fi
if [ $PG_ON = 1 ]; then
  check DB17 "PostgreSQL: a console runs a statement and shows its first page" 'has "DRIVE mark pg-first-rows" && has "waitlabel .500 rows loaded. -> 1"' "shots/light-12-postgres.png"
fi
check DB35 "Return opens the clicked cell for editing: on a new row while its first cell is still being edited, after Escape, and after switching to another file" 'between added-row escaped | grep -q "fieldp email -> ok" && between escaped edited | grep -q "fieldp country -> ok" && between escaped edited | grep -q "fieldp name -> ok" && between switched manual-applied | grep -q "fieldp name -> ok"' "$(between added-row manual-applied | grep -E "DRIVE (firstResponder|fieldp)" | tr "\n" " ")"
check DB33 "Command-hover underlines a table name of the attached data source, not other names, and Command-click opens the table" 'between history-inserted table-link | grep -q "cmdhover orders underline=1 whole=1 hand=1" && between history-inserted table-link | grep -q "cmdhover order_count underline=0" && between table-link table-link-opened | grep -q "axfind Rows of orders -> [1-9]"' "$(between history-inserted table-link | grep "cmdhover" | tr "\n" " ")shots/light-23-table-link.png, shots/dark-23-table-link.png"
if [ $PG_ON = 1 ]; then
  check DB34 "PostgreSQL: Command-hover underlines a schema-qualified table name and Command-click opens it" 'after pg-counted | grep -q "cmdhover public.golens_journey_items underline=1 whole=1" && between pg-counted pg-table-link | grep -q "axfind Rows of golens_journey_items -> [1-9]"' "$(after pg-counted | grep -m1 "cmdhover"); shots/light-24-postgres-table-link.png"
fi
if [ $PG_ON = 1 ]; then
  check DB39 "PostgreSQL: Show Referenced Row opens the referenced table filtered by the key, and Show Referencing Rows opens the table that points at the row" 'between pg-orders-open referenced | grep -q "axfind name, b -> [1-9]" && between pg-orders-open referenced | grep -q "axfind name, c -> 0" && between referenced referencing | grep -q "axfind id, 10 -> [1-9]" && between referenced referencing | grep -q "axfind id, 11 -> [1-9]"' "$(between pg-orders-open referencing | grep -E "rowmenu .* perform|axfind" | tr "\n" " ")shots/light-28-referenced-row.png, shots/light-29-referencing-rows.png"
  check DB40 "Run SQL lenses run a database/sql string with a bound \$1 and a pgx string, titled by the Go file and line" 'between go-open go-sql-ran | grep -q "lensclick Run SQL" && between go-open go-sql-ran | grep -q "waitlabel .Query Parameters. -> 1" && between go-open go-sql-ran | grep -q "waitlabel .store.go:. -> 1" && between go-open go-sql-ran | grep -q "axfind name, b -> [1-9]" && between go-sql-ran pgx-sql-ran | grep -q "axfind name, c -> [1-9]"' "shots/light-25-run-sql-lens.png, shots/light-26-go-sql-result.png"
  check DB41 "Completion inside a backquoted Go SQL string lists a column, and typing in a plain Go string opens no SQL completion" 'between pgx-sql-ran go-completion | grep -m1 "^DRIVE panel" | grep -q "name" && ! between go-completion go-plain-string | grep -m1 "^DRIVE panel" | grep -q "golens_journey_items"' "$(between pgx-sql-ran go-plain-string | grep "^DRIVE panel" | cut -c1-200 | tr "\n" " ")shots/light-27-go-sql-completion.png"
  check DB42 "Run Query runs a sqlc query with sqlc.arg bound through the parameter sheet" 'between sqlc-open sqlc-ran | grep -q "waitlabel .Query Parameters. -> 1" && between sqlc-open sqlc-ran | grep -q "axfind name, c -> [1-9]"' "shots/light-30-sqlc-run-query.png"
  check DB43 "Edit Data Source… opens a data source that connects through SSH with its SSH Tunnel section and destination field" 'grep -q "fieldp user@bastion or a Host alias -> ok" "$SHORT_LOG" && grep -m1 "^DRIVE deeplabels" "$SHORT_LOG" | grep -q "SSH Tunnel"' "shots/light-31-ssh-section.png, shots/dark-31-ssh-section.png"
fi
if [ -n "${GOLENS_TEST_SSH_DEST:-}" ] && [ $PG_ON = 1 ]; then
  check DB44 "PostgreSQL through an SSH tunnel runs a statement while one ssh -N -L process is running" 'has "axfind through_ssh, 42 -> [1-9]" && [ -s "$WORK/ssh-pids" ]' "ssh pids during the run: $(cat "$WORK/ssh-pids" 2>/dev/null | tr "\n" " ")"
fi
check DB45 "No ssh -N -L tunnel process outlives the app" '[ -z "$SSH_LEFT" ]' "left: ${SSH_LEFT:-none}"
check DB18 "The journey reached the end" 'has "DRIVE mark done"' ""

p95() { sort -n | awk 'NF{a[n++]=$1} END{if(n){i=int(n*0.95); if(i>=n)i=n-1; print a[i]}}'; }
WARM=$(grep "database first rows shown" "$APPLOG" | sed -n '2,21p' | sed -E 's/.*overhead ([0-9.]+) ms.*/\1/')
WARM_P95=$(echo "$WARM" | p95)
check DB19 "First rows on screen within 50 ms after the core returns (p95 of 20 warm runs)" '[ -n "$WARM_P95" ] && awk "BEGIN{exit !($WARM_P95 <= 50.0)}"' "p95 $WARM_P95 ms; warm overhead ms: $(echo $WARM | tr ' ' '\n' | sort -n | tr '\n' ' ')"
COMP=$(grep "completion sql" "$APPLOG" | sed -E 's/.*completion sql ([0-9.]+) ms.*/\1/' | sort -n)
COMP_P95=$(echo "$COMP" | p95)
check DB20 "Completion answers within 30 ms (p95)" '[ -n "$COMP_P95" ] && awk "BEGIN{exit !($COMP_P95 <= 30.0)}"' "samples: $(echo $COMP)"

fail=0
printf '\n%-5s %-6s  %s\n' ID RESULT CHECK
while IFS=$'\t' read -r id name status ev; do
  [ "${DATABASE_JOURNEY_GO_ONLY:-0}" = 1 ] && ! echo "$id" | grep -qE '^DB(39|4[0-5]|18)$' && continue
  [ "${DATABASE_JOURNEY_PERF_ONLY:-0}" = 1 ] && ! echo "$id" | grep -qE '^DB([1-6]|8b?|18|19|45)$' && continue
  [ "$status" = FAIL ] && fail=$((fail + 1))
  printf '%-5s %-6s  %s\n        %s\n' "$id" "$status" "$name" "$ev"
done < "$RESULTS"
echo
grep "database first rows shown\|database response on main" "$APPLOG" | sed 's/^/  /'
echo "Runtime: $(( $(date +%s) - START ))s. Artifacts: $ART"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
