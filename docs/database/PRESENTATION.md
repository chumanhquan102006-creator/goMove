# Trình bày Database GoMove với giảng viên (3–5 phút)

## Gợi ý thứ tự trình bày

**0:00–0:30 – Tổng quan.** “Em thiết kế cơ sở dữ liệu PostgreSQL 16 tích hợp PostGIS 3.5 cho ứng dụng đặt xe GoMove. Cấu trúc được quản lý bằng Flyway, hiện có 13 migration V1–V13 trên GitHub. Em tách rõ tài khoản, tài xế/xe/GPS, báo giá/đặt xe, offer và thanh toán.”

**0:30–1:30 – ERD.** Mở `erd.png` hoặc `ERD.md` ngay trên GitHub, chỉ theo luồng `users → quotes → bookings → cash_payments`. Giải thích `drivers` nối với `users`, `vehicles`, `driver_locations` và các `booking_driver_offers`. Thảo luận quan hệ 1:N và các quan hệ 1:0..1 bằng FK + UNIQUE.

**1:30–2:20 – Constraint và tính đúng đắn.** Ví dụ một `quote_id` tạo tối đa một booking; một tài xế tối đa một xe active; offer đúng 15 giây; cập nhật booking trạng thái theo thứ tự; chi phí CASH và commission có ràng buộc chính xác và ledger không thể sửa/xóa.

**2:20–3:15 – Demo trên DBeaver.** Mở `public → Tables` và `public → Diagram`, trình bày một số bảng. Mở SQL Script từ `DEMO_QUERIES.sql`, chạy câu 02 (Flyway), 04 (đếm dòng), 06 (join), 08 (offer), 09/10 (payment/commission). Không hiển thị số điện thoại, license, token/password hash hay GPS người dùng thật.

**3:15–4:10 – Đường đi của dữ liệu thật.** App Flutter Customer gọi Spring Boot tạo Quote và Booking; DB giữ `SEARCHING_DRIVER`, Driver gửi GPS gần pickup vào PostGIS; dispatch tìm Driver phù hợp và gửi offer; Driver Accept hợp lệ chuyển booking sang `DRIVER_ACCEPTED` và Driver `BUSY`. Nếu luồng chưa chạy đủ trên thực tế, nói rõ bước nào đã được xác minh.

**4:10–5:00 – Quản lý phiên bản & an toàn.** Flyway giúp thay đổi schema có thứ tự và kiểm tra lịch sử; migrations đã áp dụng không được chỉnh sửa. Không upload dump DB cá nhân lên GitHub; chỉ gửi migration, ERD, tài liệu và dữ liệu minh họa giả/đã ẩn danh.

## Cách thao tác ERD trong DBeaver

1. Mở DBeaver, kết nối `gomove` và chọn `Databases → gomove → Schemas → public`.
2. Chọn tab **Diagram** để thấy sơ đồ tự tạo từ FK thật. Có thể kéo bảng và dùng zoom.
3. Nếu sơ đồ quá nhiều thành phần, chỉ chọn nhóm bảng nghiệp vụ, tạo diagram mới hoặc sử dụng `erd.png` trong repo.
4. Có thể xuất hình từ toolbar/menu diagram; tắt hoặc che tên/định danh người dùng nếu chụp dữ liệu.

## Thực hành truy vấn

- **Flyway:** `SELECT version, description, success FROM flyway_schema_history ORDER BY installed_rank;`
- **PK/FK:** mở `bookings` → Properties → Columns/Foreign Keys/Indexes trong DBeaver.
- **JOIN:** truy vấn 06 trong `DEMO_QUERIES.sql` cho thấy `bookings` kết hợp `quotes` và `cash_payments`.
- **Tiền:** `final_fare` được chấp nhận tại thời điểm đặt xe; payment CASH PAID không đồng nghĩa commission đã chuyển tiền.

## Reproduce schema từ repository

- Migrations `backend/src/main/resources/db/migration/V1...V13` **là nguồn DDL chuẩn**, đã nằm trên GitHub. Khi chạy Backend với PostgreSQL/PostGIS trống, Flyway tự áp theo thứ tự.
- Tùy yêu cầu của giảng viên, có thể xuất một bản **schema-only** để tham khảo:

```powershell
# Chạy từ máy có Docker Desktop và gomove-postgres đang hoạt động.
# File có thể chứa DDL mở rộng PostGIS, owner/extension metadata;
# nên review trước khi đưa lên GitHub public.
cd D:\goMove
docker exec gomove-postgres pg_dump -U gomove -d gomove --schema-only --no-owner --no-privileges > D:\GoMove-schema-only.sql
```

**Không nên đưa toàn bộ `pg_dump` schema-only lên GitHub nếu tài liệu Flyway đã đủ:** dump có thể chứa DDL PostGIS khó đọc và trùng lặp. Nếu giảng viên yêu cầu “file .sql”, 13 file migration SQL trong GitHub chính là cách quản lý chuyên nghiệp hơn, có thể cung cấp đường dẫn kèm giải thích.

## Trả lời một số câu hỏi của thầy

**Vì sao PostgreSQL, không phải SQL Server?** PostgreSQL miễn phí, hỗ trợ transaction và PostGIS để tìm tài xế theo khoảng cách. DBeaver là ứng dụng GUI quản lý như SSMS đối với SQL Server.

**Khóa `public_id` để làm gì?** Bên trong DB join bằng BIGINT; API dùng UUID để không lộ ID tuần tự hoặc internal ID.

**Vì sao GPS là `GEOGRAPHY(Point,4326)`?** Có thể truy vấn tọa độ địa lý và khoảng cách tính theo mét với PostGIS.

**Vì sao bảng `booking_idempotency`?** Để retry request mạng không tự tạo thêm booking; key UNIQUE trong phạm vi customer.

**Vì sao có Flyway?** Để kiểm soát phiên bản cấu trúc thay vì sửa thủ công trên từng máy.

## Số liệu minh họa được xác minh ngày 15/10/2026

Trong buổi trình bày có thể nói: “Đến ngày 15/10, Flyway đã áp dụng thành công đủ 13 migration. Database demo có 3 tài khoản, 1 tài xế, 1 phương tiện, 3 báo giá, 3 Booking và 3 payment rows; ledger hoa hồng chưa có bản ghi vì chưa hoàn tất giao dịch CASH thực tế.” **Không coi ba offer là ba Accept hoặc ba payment là ba PAID**. Xem [`VERIFIED_SNAPSHOT_2026-10-15.md`](VERIFIED_SNAPSHOT_2026-10-15.md).
