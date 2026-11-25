-- name: GetUser :one
SELECT id, name, email FROM users
WHERE id = $1;

-- name: ListUsers :many
SELECT * FROM users ORDER BY id;

-- name: DeleteUser :exec
DELETE FROM users WHERE id = $1;

-- name: RenameUsers :batchexec
UPDATE users SET name = $2 WHERE id = $1;

-- name: CopyUsers :copyfrom
INSERT INTO users (name, email) VALUES ($1, $2);
