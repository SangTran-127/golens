-- name: GetUser :one
SELECT id, name, email FROM users
WHERE id = ?;

-- name: ListUsers :many
SELECT * FROM users ORDER BY id;

-- name: DeleteUser :exec
DELETE FROM users WHERE id = ?;
