UPDATE orders SET status = 'void' WHERE id = 1;

SELECT status, count(*) AS orders FROM orders GROUP BY status;
