package main

import "context"

type Execer interface {
	ExecContext(ctx context.Context, query string, args ...any) error
}

type SQLRepository struct {
	db Execer
}

func NewSQLRepository(db Execer) *SQLRepository {
	return &SQLRepository{db: db}
}

const insertOrderSQL = "INSERT INTO orders (id, sku, qty) VALUES (?, ?, ?)"

func (r *SQLRepository) Save(ctx context.Context, o Order) error {
	return r.db.ExecContext(ctx, insertOrderSQL, o.ID, o.SKU, o.Qty)
}

type memoryExecer struct {
	rows [][]any
}

func newMemoryExecer() *memoryExecer {
	return &memoryExecer{}
}

func (m *memoryExecer) ExecContext(_ context.Context, _ string, args ...any) error {
	m.rows = append(m.rows, args)
	return nil
}
