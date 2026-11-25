#!/bin/bash
set -euo pipefail

PG_NAME=golens-test-postgres
MYSQL_NAME=golens-test-mysql
MARIADB_NAME=golens-test-mariadb
LABEL=app.golens.test=db
PG_PORT=54329
MYSQL_PORT=33069
MARIADB_PORT=33070
PASSWORD=golens-test

say() { echo "$*" >&2; }

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    say "Docker is not installed, so the engine tests will be skipped."
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    say "Docker is not running, so the engine tests will be skipped. Start Docker and run this again."
    exit 1
  fi
}

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]; }

start_postgres() {
  if running "$PG_NAME"; then return; fi
  docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$PG_NAME" --label "$LABEL" -p "127.0.0.1:$PG_PORT:5432" \
    -e POSTGRES_USER=golens -e POSTGRES_PASSWORD="$PASSWORD" -e POSTGRES_DB=golens \
    postgres:17 -c ssl=on \
    -c ssl_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem \
    -c ssl_key_file=/etc/ssl/private/ssl-cert-snakeoil.key >/dev/null
}

start_mysql() {
  if running "$MYSQL_NAME"; then return; fi
  docker rm -f "$MYSQL_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$MYSQL_NAME" --label "$LABEL" -p "127.0.0.1:$MYSQL_PORT:3306" \
    -e MYSQL_ROOT_PASSWORD="$PASSWORD" -e MYSQL_DATABASE=golens \
    mysql:8.4 >/dev/null
}

start_mariadb() {
  if running "$MARIADB_NAME"; then return; fi
  docker rm -f "$MARIADB_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$MARIADB_NAME" --label "$LABEL" -p "127.0.0.1:$MARIADB_PORT:3306" \
    -e MARIADB_ROOT_PASSWORD="$PASSWORD" -e MARIADB_DATABASE=golens \
    mariadb:11.4 >/dev/null
}

wait_for() {
  local name=$1; shift
  for _ in $(seq 1 120); do
    if docker exec "$name" "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  say "$name did not become ready within 120 seconds."
  docker logs --tail 30 "$name" >&2 || true
  exit 1
}

case "${1:-}" in
  up)
    require_docker
    start_postgres
    start_mysql
    start_mariadb
    wait_for "$PG_NAME" psql -U golens -d golens -h 127.0.0.1 -c 'SELECT 1'
    wait_for "$MYSQL_NAME" mysql -uroot -p"$PASSWORD" -h 127.0.0.1 -e 'SELECT 1'
    wait_for "$MARIADB_NAME" mariadb -uroot -p"$PASSWORD" -h 127.0.0.1 -e 'SELECT 1'
    echo "export GOLENS_TEST_PG_DSN='postgres://golens:$PASSWORD@127.0.0.1:$PG_PORT/golens'"
    echo "export GOLENS_TEST_MYSQL_DSN='mysql://root:$PASSWORD@127.0.0.1:$MYSQL_PORT/golens'"
    echo "export GOLENS_TEST_MARIADB_DSN='mysql://root:$PASSWORD@127.0.0.1:$MARIADB_PORT/golens'"
    ;;
  down)
    require_docker
    ids=$(docker ps -aq --filter "label=$LABEL")
    if [ -n "$ids" ]; then
      docker rm -f $ids >/dev/null
      say "Removed the GoLens test database containers."
    fi
    ;;
  *)
    say "usage: scripts/db/engines.sh up|down  (up prints export lines: eval \"\$(scripts/db/engines.sh up)\")"
    exit 2
    ;;
esac
