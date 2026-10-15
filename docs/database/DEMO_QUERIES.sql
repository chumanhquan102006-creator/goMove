-- GoMove Database – read-only presentation queries
-- Execute on PostgreSQL database "gomove", schema "public", using DBeaver.
-- All queries are read-only and avoid exposing phone numbers, hashes, or tokens.

-- 01. PostgreSQL / PostGIS platform
SELECT current_database() AS database_name,
       current_setting('server_version') AS postgres_version,
       postgis_version() AS postgis_version;

-- 02. Migration history: expect V1–V13 success on a fully upgraded backend
SELECT installed_rank, version, description, success
FROM flyway_schema_history
ORDER BY installed_rank;

-- 03. Project tables in public, excluding platform-maintained spatial_ref_sys
SELECT tablename
FROM pg_catalog.pg_tables
WHERE schemaname = 'public'
  AND tablename NOT IN ('spatial_ref_sys', 'flyway_schema_history')
ORDER BY tablename;

-- 04. Aggregated row counts (no personal data)
SELECT 'users' AS table_name, count(*) AS row_count FROM users
UNION ALL SELECT 'refresh_tokens', count(*) FROM refresh_tokens
UNION ALL SELECT 'drivers', count(*) FROM drivers
UNION ALL SELECT 'vehicles', count(*) FROM vehicles
UNION ALL SELECT 'driver_locations', count(*) FROM driver_locations
UNION ALL SELECT 'quotes', count(*) FROM quotes
UNION ALL SELECT 'bookings', count(*) FROM bookings
UNION ALL SELECT 'booking_idempotency', count(*) FROM booking_idempotency
UNION ALL SELECT 'booking_driver_offers', count(*) FROM booking_driver_offers
UNION ALL SELECT 'cash_payments', count(*) FROM cash_payments
UNION ALL SELECT 'driver_commission_ledger', count(*) FROM driver_commission_ledger
UNION ALL SELECT 'foundation_spatial_check', count(*) FROM foundation_spatial_check
ORDER BY table_name;

-- 05. State distribution (for demo status discussion)
SELECT status AS booking_status, count(*) AS amount
FROM bookings
GROUP BY status ORDER BY status;

-- 06. Customer Booking joined to Quote/Payment, with no identifiers
SELECT b.status AS booking_status,
       b.vehicle_type,
       b.final_fare AS fare_vnd,
       q.status AS quote_status,
       coalesce(cp.status, 'NO_ROW') AS cash_payment_status,
       b.created_at::date AS booking_date
FROM bookings b
JOIN quotes q ON q.id = b.quote_id
LEFT JOIN cash_payments cp ON cp.booking_id = b.id
ORDER BY b.created_at DESC LIMIT 10;

-- 07. Driver eligibility (aggregated, no license plate / GPS / names)
SELECT d.approval_status, d.operating_status,
       count(*) AS total_drivers,
       count(*) FILTER (WHERE v.is_active) AS active_vehicle_joins
FROM drivers d
LEFT JOIN vehicles v ON v.driver_id = d.id
GROUP BY d.approval_status, d.operating_status
ORDER BY d.approval_status, d.operating_status;

-- 08. Active offers and 15-second lease
SELECT o.status,
       count(*) AS offer_count,
       min(extract(epoch FROM (o.expires_at - o.offered_at))) AS min_lease_seconds,
       max(extract(epoch FROM (o.expires_at - o.offered_at))) AS max_lease_seconds
FROM booking_driver_offers o
GROUP BY o.status ORDER BY o.status;

-- 09. Cash payment counts, totals: no private transaction details
SELECT status, currency_code, count(*) AS payment_count,
       sum(amount) AS total_fare_vnd
FROM cash_payments
GROUP BY status, currency_code ORDER BY status;

-- 10. Commission accrued (RECEIVABLE; not actual funds collected)
SELECT event_type, currency_code, count(*) AS ledger_events,
       sum(commission_amount) AS accrued_commission_vnd
FROM driver_commission_ledger
GROUP BY event_type, currency_code;

-- 11. Foreign keys for the schema (names and table connections)
SELECT tc.table_name AS child_table, kcu.column_name AS fk_column,
       ccu.table_name AS parent_table, ccu.column_name AS parent_column,
       tc.constraint_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name = kcu.constraint_name AND tc.constraint_schema = kcu.constraint_schema
JOIN information_schema.constraint_column_usage ccu
  ON tc.constraint_name = ccu.constraint_name AND tc.constraint_schema = ccu.constraint_schema
WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = 'public'
ORDER BY child_table, tc.constraint_name, fk_column;
-- For exact column-to-column mapping in COMPOSITE foreign keys, inspect the
-- table constraints in DBeaver or PostgreSQL pg_catalog (this query lists related columns).

-- 12. Tables/columns and data types – source for DBeaver explanation
SELECT table_name, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('users','drivers','vehicles','driver_locations','quotes','bookings',
    'booking_driver_offers','booking_idempotency','cash_payments',
    'driver_commission_ledger','refresh_tokens','foundation_spatial_check')
ORDER BY table_name, ordinal_position;
