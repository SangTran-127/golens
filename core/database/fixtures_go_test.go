package database

const goSitesFixtureSource = `package store

import (
	"context"
	"database/sql"
)

type Store struct{ db *sql.DB }

func (s *Store) User(ctx context.Context, id int64) error {
	return s.db.QueryRowContext(ctx, ` + "`SELECT id, email FROM users WHERE id = $1`" + `, id).Err()
}

// language=SQL
const recent = "SELECT * FROM orders " +
	"ORDER BY created_at DESC LIMIT 10"
`

func goIntegrationFixtures() map[string]any {
	sqlcText := "-- name: GetUser :one\nSELECT * FROM users\nWHERE id = sqlc.arg(id) AND org = @org;\n"
	sqlcRes := SqlcQuery("/Users/me/src/app/sql/queries/users.sql", sqlcText, 1)
	sqlcRes.Engine = EnginePostgres
	sqlcRes.ConfigDir = "/Users/me/src/app"
	return map[string]any{
		"go-sql-sites-response": GoSQLSites("/Users/me/src/app/store/users.go", goSitesFixtureSource, ""),
		"sqlc-query-response":   sqlcRes,
		"related-rows-request":  RelatedRowsRequest{ResultID: "r-6f1c2a9e0b7d4e31", Row: 3, Column: 1, Direction: RelatedReferenced},
		"related-rows-response": RelatedRowsResult{Targets: []RelatedTarget{
			{Schema: "public", Table: "users", Where: `"id" = 42`, Columns: []string{"id"}, Constraint: "orders_user_id_fkey"},
		}},
		"related-rows-response-error": RelatedRowsResult{Targets: []RelatedTarget{},
			Error: newError("related", "This row doesn’t reference a row in “users” because user_id is NULL.")},
	}
}
