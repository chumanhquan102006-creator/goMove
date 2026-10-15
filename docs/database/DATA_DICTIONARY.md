# GoMove – Từ điển dữ liệu (schema V13)

## Quy ước

- **PK:** khóa chính; **FK:** khóa ngoại; **UQ:** UNIQUE; **NN:** NOT NULL.
- **BIGINT `id`:** khóa nội bộ của Database; **`public_id UUID`:** định danh công khai của các thực thể được hỗ trợ.
- **`version`:** phiên bản phục vụ kiểm soát cập nhật đồng thời; `created_at` / `updated_at`: dấu thời gian.
- **`NUMERIC(15,2)`:** tiền dạng decimal chính xác, không dùng floating-point cho VND.
- `GEOGRAPHY(Point,4326)` lưu điểm GPS, index GiST dùng cho tìm trong bán kính.

## Danh mục 12 bảng và cột cốt lõi

### 1. `users` – tài khoản

| Cột | Kiểu | Vai trò |
|---|---|---|
| `id` | BIGINT | PK nội bộ |
| `public_id` | UUID | UQ định danh API |
| `phone` | VARCHAR(20) | NN, UQ, tên đăng nhập |
| `email` | VARCHAR(100) | UQ, tùy chọn |
| `password_hash` | VARCHAR(255) | NN, mật khẩu băm, tuyệt đối không xuất công khai |
| `full_name` | VARCHAR(100) | NN, tên người dùng |
| `role` | VARCHAR(20) | NN, CUSTOMER / DRIVER / ADMIN |
| `status` | VARCHAR(20) | NN, ACTIVE / LOCKED / DISABLED |
| `failed_login_attempts`, `locked_until` | INT / TIMESTAMPTZ | Đếm và khóa đăng nhập |
| `version`, `created_at`, `updated_at` | BIGINT / TIMESTAMPTZ | Metadata |

### 2. `refresh_tokens` – phiên đăng nhập

`id` BIGINT PK; `public_id` UUID UQ; `user_id` BIGINT FK → users; `token_hash` VARCHAR(64) UQ (băm SHA-256, không phải token thô); `expires_at`, `revoked_at`, `last_used_at` TIMESTAMPTZ; `replaced_by_public_id` UUID; `version`, `created_at`, `updated_at`. FK `ON DELETE CASCADE`.

### 3. `drivers` – hồ sơ tài xế

`id` BIGINT PK; `user_id` BIGINT FK → users + UQ (quan hệ 1–0..1); `public_id` UUID UQ; `license_number` VARCHAR(50) UQ; `approval_status` PENDING/APPROVED/REJECTED/SUSPENDED; `operating_status` OFFLINE/ONLINE/BUSY; `rating_average` NUMERIC(3,2) giới hạn 0–5; `total_trips` INT không âm; `version`, `created_at`, `updated_at`. DB không cho tài xế chưa duyệt ở trạng thái ONLINE/BUSY.

### 4. `vehicles` – phương tiện

`id` BIGINT PK; `driver_id` BIGINT FK → drivers; `public_id` UUID UQ; `license_plate` VARCHAR(20) UQ; `vehicle_type` MOTORBIKE/CAR_4_SEAT/CAR_7_SEAT; `brand`, `model`, `color`; `is_active` BOOLEAN; `version`, `created_at`, `updated_at`. Partial UQ index trên `(driver_id) WHERE is_active = TRUE` bảo đảm tối đa một xe hoạt động.

### 5. `driver_locations` – vị trí GPS mới nhất

`id` BIGINT PK; `driver_id` BIGINT FK → drivers + UQ; `current_location` GEOGRAPHY(Point,4326); `accuracy` DOUBLE PRECISION không âm; `bearing` DOUBLE PRECISION từ 0 đến dưới 360 độ; `updated_at` TIMESTAMPTZ; `version` BIGINT. GiST index `idx_driver_locations_current_location_gist`.

### 6. `quotes` – báo giá

| Nhóm | Cột và kiểu |
|---|---|
| Định danh | `id` BIGINT PK, `public_id` UUID UQ, `customer_id` BIGINT FK → users |
| Điểm đi/đến | `pickup_location`, `dropoff_location` GEOGRAPHY(Point,4326) |
| Tuyến đường | `distance_meters`, `duration_seconds` NUMERIC(15,3); `routing_provider` VARCHAR(40) |
| Loại xe, tiền tệ | `vehicle_type` VARCHAR(20); `currency_code` VARCHAR(3), chỉ VND |
| Thành phần giá | `base_fare`, `distance_fare`, `time_fare`, `surcharge`, `surge_amount`, `discount_amount`, `rounding_adjustment`, `final_fare` NUMERIC(15,2); `surge_multiplier` NUMERIC(8,4) |
| Chính sách | `pricing_engine_version` VARCHAR(30), `pricing_snapshot` JSONB |
| Trạng thái | `status` ISSUED/CONSUMED/EXPIRED |
| Thời điểm | `issued_at`, `expires_at`, `consumed_at`, `created_at`, `updated_at` TIMESTAMPTZ; `version` BIGINT |

CHECK đối soát: `final_fare = base_fare + distance_fare + time_fare + surcharge + surge_amount - discount_amount + rounding_adjustment`. CHECK yêu cầu `consumed_at` chỉ có khi `status = CONSUMED`. TTL 60 giây do logic Backend áp dụng; CHECK database chỉ xác nhận `expires_at > issued_at`.

### 7. `bookings` – đơn đặt xe / vòng đời chuyến

| Nhóm | Cột và kiểu |
|---|---|
| Khóa | `id` BIGINT PK; `public_id` UUID UQ; `customer_id`, `quote_id` BIGINT FK → users / quotes; `quote_id` UQ |
| Tọa độ | `pickup_location`, `dropoff_location` GEOGRAPHY(Point,4326) |
| Snapshot | `distance_meters`, `duration_seconds` NUMERIC(15,3); `routing_provider`, `vehicle_type`, `currency_code`, `pricing_engine_version` VARCHAR; `final_fare` NUMERIC(15,2), `pricing_snapshot` JSONB |
| Dispatch | `assigned_driver_id`, `assigned_vehicle_id` BIGINT FK nullable; `next_dispatch_at` TIMESTAMPTZ; `driver_accepted_at` TIMESTAMPTZ |
| Chuyến | `status` REQUESTED / SEARCHING_DRIVER / DRIVER_ACCEPTED / DRIVER_ARRIVED / PASSENGER_ONBOARD / IN_PROGRESS / COMPLETED |
| Thời điểm chuyến | `driver_arrived_at`, `passenger_onboard_at`, `trip_started_at`, `trip_completed_at`, `driver_released_at` TIMESTAMPTZ nullable |
| Metadata | `version` BIGINT; `created_at`, `updated_at` TIMESTAMPTZ |

UQ `(quote_id)`; FK phức hợp `(assigned_vehicle_id, assigned_driver_id)` → `vehicles(id,driver_id)` để ngăn gán xe của người khác. CHECK V12 bảo vệ bộ timestamp theo từng trạng thái. Partial UQ `uq_bookings_active_driver`: một Driver không được có hai Booking **chưa release**.

### 8. `booking_idempotency` – chống đặt trùng

`id` BIGINT PK; `customer_id` BIGINT FK → users; `idempotency_key` VARCHAR(128); `request_hash` VARCHAR(64) hex; `booking_id` BIGINT FK → bookings (nullable); `http_status` SMALLINT; `response_body` JSONB; `created_at` TIMESTAMPTZ. UQ `(customer_id, idempotency_key)`; CHECK kết quả lưu gồm Booking ID, HTTP 201 và response nếu giao dịch thành công.

### 9. `booking_driver_offers` – đề nghị tài xế

`id` BIGINT PK; `public_id` UUID UQ; `booking_id` BIGINT FK → bookings; `driver_id` BIGINT FK → drivers; `vehicle_id` BIGINT FK → vehicles (phức hợp với driver); `status` PENDING/ACCEPTED/REJECTED/EXPIRED; `offered_at`, `expires_at`, `responded_at` TIMESTAMPTZ; `version`, `created_at`, `updated_at`.

CHECK chính xác `expires_at = offered_at + INTERVAL '15 seconds'`; UQ `(booking_id,driver_id)`, partial UQ ngăn nhiều PENDING cho cùng Booking/Driver và nhiều ACCEPTED cho cùng Booking.

### 10. `cash_payments` – thanh toán tiền mặt

`id` BIGINT PK; `public_id` UUID UQ; `booking_id` BIGINT FK → bookings + UQ; `method` chỉ CASH; `status` PENDING/PAID; `amount` NUMERIC(15,2); `currency_code` chỉ VND; `collected_by_driver_id` BIGINT FK (nullable, ràng buộc tới tài xế được gán Booking); `paid_at` TIMESTAMPTZ; `version`, `created_at`, `updated_at`.

Trigger `trg_cash_payment_booking` bắt buộc số tiền khớp Booking, chỉ PAID sau khi chuyến COMPLETED, ngăn xóa payment và sửa payment đã PAID.

### 11. `driver_commission_ledger` – công nợ hoa hồng

`id` BIGINT PK; `public_id` UUID UQ; `booking_id` BIGINT FK → bookings; `driver_id` BIGINT FK → drivers; `event_type` chỉ COMMISSION_ACCRUED; `currency_code` VND; `gross_cash_fare` NUMERIC(15,2); `commission_rate` NUMERIC(12,10) trong 0–1; `commission_amount` NUMERIC(15,2); `commission_policy_version` VARCHAR(40); `occurred_at`, `created_at` TIMESTAMPTZ.

UQ `(booking_id,event_type)`; CHECK tỷ lệ, số tiền và quy tắc làm tròn; trigger chỉ cho ghi khi Booking COMPLETED, trigger append-only chặn UPDATE/DELETE. **Đây là khoản hoa hồng phải thu của nền tảng, không chứng minh tiền đã chuyển về nền tảng.**

### 12. `foundation_spatial_check` – kiểm tra PostGIS

`id` BIGINT PK; `public_id` UUID UQ; `name` VARCHAR(100); `location` GEOGRAPHY(Point,4326); `version`, `created_at`, `updated_at`; GiST index. Không tham gia khóa ngoại nghiệp vụ đặt xe.

## Phân biệt bảng do ứng dụng tạo / thành phần hệ thống

- **Flyway:** `flyway_schema_history` – bảng lịch sử áp dụng migration, được Flyway quản lý, không tính vào 12 bảng tạo bởi các migration của dự án.
- **PostGIS:** `spatial_ref_sys` (danh mục hệ tọa độ); `geography_columns`, `geometry_columns` thường là view metadata; schema `tiger`, `tiger_data`, `topology` thuộc extension.

## Nguồn DDL và giới hạn

Tất cả các tên bảng, cột, kiểu và ràng buộc nêu trên được đối chiếu từ các migration `backend/src/main/resources/db/migration/V1...V13`. Bản mô tả này không bao gồm danh sách toàn bộ index/triggers hệ thống PostgreSQL; để xem chính xác, mở SQL source trong repo hoặc DBeaver → table → Properties/DDL.
