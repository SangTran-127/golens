SELECT * FROM orders;

SELECT count(*) AS order_count FROM orders;

DELETE FROM orders;

SELECT o.id, o.total, c.name FROM orders o CROSS JOIN customers c;

SELECT o.c FROM orders o WHERE o.id < 10;

WITH RECURSIVE r(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM r) SELECT count(*) FROM r;

BEGIN;

INSERT INTO notes (body) VALUES ('draft from the database journey');

SELECT name FROM customers WHERE name = :name;

SELECT * FROMM orders;
