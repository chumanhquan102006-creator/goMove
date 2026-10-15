# GoMove – Tài liệu cơ sở dữ liệu

> Bản mô tả schema tính đến **Flyway V13**, đối chiếu mã nguồn trên nhánh `main` ngày 15/10/2026. **Đã bổ sung số liệu môi trường development được kiểm chứng bằng DBeaver ngày 15/10/2026**; số liệu là snapshot theo thời điểm, không cố định.

## 1. Tổng quan

**GoMove** là hệ thống đặt xe gồm người đặt xe (**CUSTOMER**), tài xế (**DRIVER**) và người quản trị (**ADMIN**). Backend Java/Spring Boot kết nối PostgreSQL; PostGIS hỗ trợ tìm tài xế theo khoảng cách, Flyway quản lý thay đổi cấu trúc CSDL.

| Thành phần | Công nghệ / đặc điểm |
| --- | --- |
| CSDL quan hệ | PostgreSQL 16 (image `postgis/postgis:16-3.5`) |
| Mở rộng địa lý | PostGIS 3.5, `GEOGRAPHY(Point,4326)` |
| Quản lý schema | Flyway, 13 migration `V1`–`V13` |
| Khóa chính | `BIGINT` nội bộ; UUID `public_id` cho API khi có |
| Phân quyền | `users.role`: CUSTOMER / DRIVER / ADMIN |
| Dữ liệu giá | `NUMERIC`, VND, báo giá và giá booking chụp snapshot |
| CSDL trên máy dev | Container `gomove-postgres`, cổng 5432, database `gomove` |

**Số bảng tạo bởi các migration V1–V13: 12**, gồm **11 bảng chức năng** và **1 bảng kiểm tra không gian** (`foundation_spatial_check`). Flyway tạo riêng `flyway_schema_history`. PostGIS tạo `spatial_ref_sys` và các view metadata như `geography_columns`, `geometry_columns`; **đây không phải bảng nghiệp vụ GoMove**.

## 2. Các nhóm bảng

| Nhóm | Bảng | Mục đích |
| --- | --- | --- |
| Tài khoản | `users`, `refresh_tokens` | Người dùng, vai trò, quản lý phiên đăng nhập |
| Tài xế và xe | `drivers`, `vehicles`, `driver_locations` | Hồ sơ, duyệt tài xế, phương tiện, tọa độ GPS mới nhất |
| Báo giá/đặt xe | `quotes`, `bookings`, `booking_idempotency` | Báo giá có hạn, đơn đặt xe, chống yêu cầu trùng |
| Ghép chuyến | `booking_driver_offers` | Gửi đề nghị có hạn 15 giây cho tài xế |
| Thanh toán | `cash_payments`, `driver_commission_ledger` | CASH PENDING/PAID và hoa hồng phải thu |
| Hỗ trợ | `foundation_spatial_check` | Kiểm tra nền tảng PostGIS |

## 3. Sơ đồ quan hệ

- [ERD rút gọn và toàn bộ quan hệ](ERD.md) (hỗ trợ Mermaid trên GitHub)
- [Ảnh ERD dễ chiếu](erd.png) / [SVG sắc nét](erd.svg)
- [Từ điển dữ liệu – bảng, khóa và các cột](DATA_DICTIONARY.md)
- [Câu SQL kiểm tra/demo](DEMO_QUERIES.sql)
- [Hướng dẫn trình bày](PRESENTATION.md)
- [Snapshot kiểm chứng từ DBeaver ngày 15/10/2026](VERIFIED_SNAPSHOT_2026-10-15.md)
- [Checklist và bằng chứng trên máy thật](EVIDENCE_CHECKLIST.md)

## 4. Luồng nghiệp vụ ↔ CSDL

1. **Đăng ký/đăng nhập:** `users` ghi tài khoản; `refresh_tokens` lưu **băm** token (không lưu token thô).
2. **Driver onboarding:** hồ sơ `drivers` gắn một `users`, cần `APPROVED`; mỗi driver có thể có nhiều `vehicles`, tối đa một xe đang `is_active = TRUE`.
3. **GPS:** `driver_locations` lưu vị trí cuối của mỗi tài xế, có GiST index hỗ trợ truy vấn bán kính bằng PostGIS. Khi dispatch chỉ chọn GPS đủ mới.
4. **Báo giá:** `quotes` gồm tọa độ, OSRM distance/duration, cấu phần giá, `pricing_snapshot JSONB`, `ISSUED/CONSUMED/EXPIRED`, hạn dùng **60 giây do Backend áp dụng**.
5. **Đặt xe:** `bookings` sao chép thông tin và giá chấp nhận từ quote. `UNIQUE(quote_id)` + `booking_idempotency` chống tạo hai đơn từ cùng báo giá/khóa nghiệp vụ.
6. **Ghép tài xế:** `booking_driver_offers` ghi offer và `expires_at = offered_at + 15 seconds`; chấp nhận hợp lệ mới gán driver/vehicle và chuyển driver `BUSY`.
7. **Vòng đời chuyến:** `bookings.status`: REQUESTED → SEARCHING_DRIVER → DRIVER_ACCEPTED → DRIVER_ARRIVED → PASSENGER_ONBOARD → IN_PROGRESS → COMPLETED (điều kiện chuyển trạng thái do Backend kiểm soát).
8. **CASH:** `cash_payments` tạo PENDING khi đặt xe, chỉ PAID sau COMPLETED được xác nhận; `driver_commission_ledger` thêm bản ghi COMMISSION_ACCRUED, **không phải bằng chứng nền tảng đã thu tiền hoa hồng**.

## 5. Những ràng buộc thiết kế đáng trình bày

- **PK/FK và UUID:** CSDL dùng khóa số để join hiệu quả; API chỉ xuất UUID công khai; `users`–`drivers` 1–0..1 qua `drivers.user_id UNIQUE`.
- **One active vehicle:** partial unique index `ux_vehicles_one_active_per_driver`.
- **One quote → max one booking:** `uq_bookings_quote_id`.
- **Idempotency theo khách:** `uq_booking_idempotency_customer_key`.
- **Offer chính xác 15 giây:** `chk_offer_exact_lease`; các unique partial index ngăn 2 offer PENDING cùng lúc cho cùng booking/driver.
- **Một assignment đang giữ:** `uq_bookings_active_driver` lọc `driver_released_at IS NULL`.
- **Tiền:** `quotes.chk_quotes_fare_reconciliation`, `cash_payments` giữ đúng giá chấp nhận, ledger `NUMERIC` và kiểm tra commission.
- **Bất biến lịch sử:** trigger từ V13 ngăn sửa/xóa ledger đã ghi và chặn sửa thanh toán PAID.
- **GPS:** `GEOGRAPHY(Point,4326)` + GiST; thứ tự tạo point nội bộ là `(longitude, latitude)`.

## 6. Tái tạo database từ GitHub

**Schema chuẩn được lưu ở** [`backend/src/main/resources/db/migration/`](../../backend/src/main/resources/db/migration/) với `V1`–`V13`. Không chạy thủ công từng migration lên database đã được Flyway quản lý, và **không sửa V1–V13**.

```powershell
# Từ thư mục gốc repository
cd D:\goMove
docker compose up -d postgres
docker compose ps

# Ở cửa sổ khác: cấu hình JWT_SECRET trong môi trường dev rồi chạy backend
cd D:\goMove\backend
.\mvnw.cmd spring-boot:run
```

Khi Spring Boot khởi động, Flyway sẽ áp các migration chưa thực hiện; kiểm tra kết quả bằng `SELECT version, description, success FROM flyway_schema_history ORDER BY installed_rank;`. Không dùng `docker compose down -v` trên DB đang chứa dữ liệu thật.

**Bảo mật khi đăng GitHub public:** Chỉ đưa schema, ERD, câu truy vấn và **dữ liệu giả đã kiểm duyệt**; không đưa file `.env`, mật khẩu, `JWT_SECRET`, `password_hash`, `token_hash`, số điện thoại thật, vị trí GPS của người thật hoặc dump đầy đủ DB đang chạy.

## 7. Kết quả kiểm chứng trên PostgreSQL development (15/10/2026)

DBeaver đã cho thấy **13/13 Flyway migrations V1–V13 thành công**, cùng `users = 3`, `drivers = 1`, `vehicles = 1`, `driver_locations = 1`, `quotes = 3`, `bookings = 3`, `booking_driver_offers = 3`, `cash_payments = 3`, `driver_commission_ledger = 0`. Đây là số liệu ảnh chụp lúc khoảng 09:27–09:28 ngày 15/10/2026, không phải dữ liệu được commit lên GitHub. Xem [snapshot và giới hạn xác minh](VERIFIED_SNAPSHOT_2026-10-15.md).
