PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;

CREATE TABLE customers (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  country TEXT NOT NULL
);

WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 5000)
INSERT INTO customers
SELECT x, 'Customer ' || x, 'customer' || x || '@example.com',
       CASE x % 4 WHEN 0 THEN 'VN' WHEN 1 THEN 'US' WHEN 2 THEN 'DE' ELSE 'JP' END
FROM c;

CREATE TABLE orders (
  id INTEGER PRIMARY KEY,
  customer_id INTEGER NOT NULL REFERENCES customers(id),
  status TEXT NOT NULL,
  total REAL NOT NULL,
  currency TEXT NOT NULL,
  quantity INTEGER NOT NULL,
  discount REAL NOT NULL DEFAULT 0,
  tax REAL NOT NULL,
  shipping REAL NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  shipped_at TEXT,
  country TEXT NOT NULL,
  city TEXT NOT NULL,
  postal_code TEXT NOT NULL,
  channel TEXT NOT NULL,
  coupon TEXT,
  note TEXT,
  payload TEXT NOT NULL,
  is_gift INTEGER NOT NULL
);

WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000000)
INSERT INTO orders
SELECT x,
       1 + x % 5000,
       CASE x % 5 WHEN 0 THEN 'paid' WHEN 1 THEN 'pending' WHEN 2 THEN 'shipped' WHEN 3 THEN 'refunded' ELSE 'canceled' END,
       round((x % 9973) * 1.37, 2),
       CASE x % 3 WHEN 0 THEN 'USD' WHEN 1 THEN 'EUR' ELSE 'VND' END,
       1 + x % 7,
       round((x % 13) * 0.5, 2),
       round((x % 9973) * 0.1, 2),
       round((x % 17) * 1.25, 2),
       datetime(1700000000 + x * 60, 'unixepoch'),
       datetime(1700000000 + x * 60 + 3600, 'unixepoch'),
       CASE WHEN x % 3 = 0 THEN datetime(1700000000 + x * 60 + 86400, 'unixepoch') END,
       CASE x % 4 WHEN 0 THEN 'VN' WHEN 1 THEN 'US' WHEN 2 THEN 'DE' ELSE 'JP' END,
       CASE x % 4 WHEN 0 THEN 'Ho Chi Minh City' WHEN 1 THEN 'Seattle' WHEN 2 THEN 'Berlin' ELSE 'Osaka' END,
       printf('%05d', x % 99991),
       CASE x % 3 WHEN 0 THEN 'web' WHEN 1 THEN 'ios' ELSE 'store' END,
       CASE WHEN x % 10 = 0 THEN 'SAVE' || (x % 50) END,
       CASE WHEN x % 7 = 0 THEN 'Leave the parcel at the front desk if nobody answers the door.' END,
       json_object('sku', 'SKU-' || (x % 1000), 'qty', 1 + x % 7, 'tags', json_array('a', 'b')),
       x % 11 = 0
FROM c;

CREATE INDEX orders_customer_id ON orders(customer_id);

CREATE TABLE notes (
  id INTEGER PRIMARY KEY,
  body TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE VIEW paid_orders AS SELECT id, customer_id, total FROM orders WHERE status = 'paid';

CREATE TABLE t (x INTEGER);
INSERT INTO t VALUES (1);

INSERT INTO customers VALUES (5001, 'Customer 5001', 'customer5001@example.com', 'VN'), (5002, 'Customer 5002', 'customer5002@example.com', 'VN'), (5003, 'Customer 5003', 'customer5003@example.com', 'VN');
