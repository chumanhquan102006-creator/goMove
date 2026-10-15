# GoMove ERD – Quan hệ các bảng nghiệp vụ

> Các đường nối thể hiện khóa ngoại của PostgreSQL; ký hiệu `o|` chỉ quan hệ **có thể không tồn tại** bản ghi phía con. ERD không vẽ các view/thành phần nội bộ của PostGIS và bảng Flyway để tránh nhiễu. `foundation_spatial_check` độc lập, là bảng kiểm tra nền tảng.

```mermaid
erDiagram
    users ||--o{ refresh_tokens : owns
    users ||--o| drivers : has_profile
    drivers ||--o{ vehicles : registers
    drivers ||--o| driver_locations : latest_gps
    users ||--o{ quotes : requests
    users ||--o{ bookings : places
    quotes ||--o| bookings : consumed_by
    users ||--o{ booking_idempotency : owns_key
    bookings o|--o{ booking_idempotency : response_of
    bookings ||--o{ booking_driver_offers : produces
    drivers ||--o{ booking_driver_offers : receives
    vehicles ||--o{ booking_driver_offers : offered_vehicle
    drivers o|--o{ bookings : assigned_to
    vehicles o|--o{ bookings : assigned_vehicle
    bookings ||--o| cash_payments : paid_by
    drivers o|--o{ cash_payments : collects
    bookings ||--o| driver_commission_ledger : accrues
    drivers ||--o{ driver_commission_ledger : owes

    users {
        bigint id PK
        uuid public_id UK
        varchar phone UK
        varchar full_name
        varchar role
        varchar status
    }
    refresh_tokens {
        bigint id PK
        bigint user_id FK
        varchar token_hash UK
        timestamptz expires_at
    }
    drivers {
        bigint id PK
        bigint user_id FK,UK
        uuid public_id UK
        varchar approval_status
        varchar operating_status
    }
    vehicles {
        bigint id PK
        bigint driver_id FK
        uuid public_id UK
        varchar vehicle_type
        boolean is_active
    }
    driver_locations {
        bigint id PK
        bigint driver_id FK,UK
        geography current_location
        timestamptz updated_at
    }
    quotes {
        bigint id PK
        bigint customer_id FK
        uuid public_id UK
        numeric final_fare
        varchar status
        timestamptz expires_at
    }
    bookings {
        bigint id PK
        bigint customer_id FK
        bigint quote_id FK,UK
        bigint assigned_driver_id FK
        bigint assigned_vehicle_id FK
        uuid public_id UK
        varchar status
        numeric final_fare
        timestamptz driver_released_at
    }
    booking_idempotency {
        bigint id PK
        bigint customer_id FK
        bigint booking_id FK
        varchar idempotency_key
        varchar request_hash
    }
    booking_driver_offers {
        bigint id PK
        bigint booking_id FK
        bigint driver_id FK
        bigint vehicle_id FK
        uuid public_id UK
        varchar status
        timestamptz expires_at
    }
    cash_payments {
        bigint id PK
        bigint booking_id FK,UK
        bigint collected_by_driver_id FK
        uuid public_id UK
        varchar status
        numeric amount
    }
    driver_commission_ledger {
        bigint id PK
        bigint booking_id FK
        bigint driver_id FK
        uuid public_id UK
        numeric commission_amount
        varchar event_type
    }
```

**Ghi chú về lực lượng quan hệ:** `bookings.quote_id` là NOT NULL + UNIQUE ⇒ một Quote có tối đa một Booking. `cash_payments.booking_id` cũng NOT NULL + UNIQUE ⇒ mỗi Booking có tối đa một Payment. `drivers.user_id UNIQUE` ⇒ một User có tối đa một Driver profile. Các FK nullable như `assigned_driver_id` không bắt buộc trong lúc tìm tài xế. `driver_commission_ledger` UNIQUE `(booking_id,event_type)` và hiện chỉ cho `COMMISSION_ACCRUED` ⇒ nhiều nhất một accrual/booking.

**Tham chiếu:** DDL chính xác và đầy đủ nằm trong Flyway V1–V13; `DATA_DICTIONARY.md` giải thích từng bảng. Tập tin `erd.png`/`erd.svg` là phiên bản hình minh họa đã đơn giản hóa để thuyết trình.
