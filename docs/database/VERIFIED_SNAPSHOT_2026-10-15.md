# GoMove – Snapshot kiểm chứng Database ngày 15/10/2026

> **Nguồn:** ảnh chụp kết quả truy vấn trực tiếp bằng DBeaver trên PostgreSQL database `gomove` do người phát triển cung cấp ngày **15/10/2026**, khoảng **09:27–09:28 (UTC+07:00)**. Đây là snapshot môi trường development tại thời điểm kiểm tra, **không phải số liệu cố định của schema**. Dữ liệu có thể thay đổi khi demo chạy tiếp.

## Kết quả Flyway

Lệnh kiểm tra:

```sql
SELECT version, description, success
FROM flyway_schema_history
ORDER BY installed_rank;
```

**Kết quả đã quan sát:** 13 bản ghi migration, lần lượt `1` đến `13`; **toàn bộ `success = TRUE`**. Migration cuối: `create cash payments and commission ledger` (V13).

## Số lượng bản ghi nghiệp vụ đã quan sát

Số liệu dưới đây chỉ là **COUNT(*)**, không kèm tên, số điện thoại, token, mã tài xế hay vị trí GPS.

| Bảng | COUNT(*) |
|---|---:|
| `users` | 3 |
| `drivers` | 1 |
| `vehicles` | 1 |
| `driver_locations` | 1 |
| `quotes` | 3 |
| `bookings` | 3 |
| `booking_driver_offers` | 3 |
| `cash_payments` | 3 |
| `driver_commission_ledger` | 0 |

Ba bảng `refresh_tokens`, `booking_idempotency`, `foundation_spatial_check` **chưa có COUNT(*) trong ảnh này**, không suy luận số lượng.

**Diễn giải chính xác:**

- `driver_commission_ledger = 0` nghĩa là tại thời điểm chụp chưa có sự kiện `COMMISSION_ACCRUED` được ghi, **không khẳng định hệ thống thanh toán lỗi**; commission chỉ ghi khi có thanh toán CASH hợp lệ sau chuyến COMPLETED.
- `booking_driver_offers = 3` cho thấy có ba bản ghi offer trong DB. **Không suy ra có ba offer được chấp nhận** nếu chưa kiểm tra `status`.
- `cash_payments = 3` là số dòng payment. **Không suy ra ba giao dịch PAID**; cần nhóm theo `status`.
- Tài xế `ONLINE` và tọa độ GPS mới đã được quan sát riêng trong DBeaver ở thời điểm kiểm thử M2; không đăng tọa độ GPS hoặc định danh người thật trong tài liệu public.

## Truy vấn bổ sung để kiểm tra khi thuyết trình

```sql
-- Số liệu còn thiếu (không tiết lộ thông tin riêng tư)
SELECT 'refresh_tokens' AS table_name, COUNT(*) AS row_count FROM refresh_tokens
UNION ALL SELECT 'booking_idempotency', COUNT(*) FROM booking_idempotency
UNION ALL SELECT 'foundation_spatial_check', COUNT(*) FROM foundation_spatial_check;

-- Phân bố trạng thái, tránh hiểu nhầm số bản ghi = số lượt thành công
SELECT status, COUNT(*) AS total FROM booking_driver_offers GROUP BY status ORDER BY status;
SELECT status, COUNT(*) AS total FROM cash_payments GROUP BY status ORDER BY status;
SELECT status, COUNT(*) AS total FROM bookings GROUP BY status ORDER BY status;
```

Các truy vấn kiểm tra khác có trong [`DEMO_QUERIES.sql`](DEMO_QUERIES.sql).

## Phạm vi xác minh và bảo mật

- Số bản ghi và 13 migration: **xác minh bằng ảnh DBeaver**.
- PostgreSQL 16/PostGIS 3.5: **khai báo theo Docker Compose**, chưa đối chiếu bằng lệnh `SELECT current_setting('server_version'), postgis_version()` trong hai ảnh trên.
- Chưa xác minh Driver Accept end-to-end và CASH PAID; không trình bày như kết quả đã chạy thật.
- Không đưa `pg_dump` có dữ liệu cá nhân, `password_hash`, `token_hash`, JWT, số điện thoại hay dữ liệu GPS định danh lên GitHub công khai.
