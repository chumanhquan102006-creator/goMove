# Bằng chứng cần bổ sung trước khi nộp (không công khai dữ liệu cá nhân)

> Ngày dự kiến hoàn tất: **Chủ nhật 18/10/2026**. Những chỗ `CHƯA_XÁC_MINH` phải được thay bằng kết quả chạy thật hoặc bỏ khỏi bài báo cáo, không bịa số liệu.

| Bằng chứng | Cách lấy | Trạng thái |
|---|---|---|
| PostgreSQL và PostGIS version | Câu 01 trong `DEMO_QUERIES.sql` | CHƯA_XÁC_MINH |
| Flyway V1–V13 áp dụng thành công | Câu 02, ảnh DBeaver 15/10/2026 | **ĐÃ_XÁC_MINH: 13/13 success** |
| Danh sách 12 bảng migration | Từ V1–V13 và ảnh DBeaver các bảng public | **ĐÃ_XÁC_MINH CẤU TRÚC** |
| Số dòng mỗi bảng | Ảnh DBeaver 15/10/2026, chỉ con số tổng hợp | **9/12 bảng ĐÃ_XÁC_MINH**; 3 bảng còn thiếu |
| ERD thực tế trên DBeaver | `public → Diagram` đã được người dùng mở, sơ đồ trong tài liệu dựa trên migrations | **ĐÃ_XÁC_MINH HIỂN THỊ** |
| Booking ↔ Quote ↔ Payment | Câu 06, ẩn danh | CHƯA_XÁC_MINH |
| Driver approval/online/GPS mới | Ảnh DBeaver và emulator M2 đã quan sát trước đó | **ĐÃ_XÁC_MINH TẠI THỜI ĐIỂM DEMO** |
| Offer/Accept nếu đã có | Câu 08 và trạng thái Booking, không khẳng định nếu chưa test | CHƯA_XÁC_MINH |
| Link GitHub chứa docs | Sau commit/merge docs | CHƯA_XÁC_MINH |

## Nguyên tắc bảo mật trước khi chụp màn hình

- Không chụp `users.phone`, `email`, `password_hash`, `refresh_tokens.token_hash`, tài khoản Admin hoặc token/JWT.
- Không upload hàng loạt dữ liệu Booking/GPS thật của người khác; chỉ trình bày số lượng/tổng hợp hoặc bộ sample vô danh.
- Mật khẩu DB trong `docker-compose.yml` chỉ phục vụ dev; không sao chép sang script, tài liệu hay ảnh với mật khẩu tài khoản thật.
- Không chia sẻ file `*.env`, keystore, `local.properties`, Access/Refresh token.
- Nếu GitHub repo công khai, hiểu rằng ảnh, SQL và docs có thể bị người ngoài truy cập.

## Kết quả thực tế (điền thủ công sau khi kiểm tra)

- PostgreSQL version: CHƯA_XÁC_MINH
- PostGIS version: CHƯA_XÁC_MINH
- Số migration success: **13/13 (15/10/2026)**
- Số bản ghi `users`: **3**
- Số bản ghi `drivers`: **1**
- Số bản ghi `bookings`: **3**
- Số bản ghi `booking_driver_offers`: **3**
- Booking tạo từ Flutter: ĐÃ ĐƯỢC NGƯỜI DÙNG QUAN SÁT TRÊN DBeaver Ở GIAI ĐOẠN M1; ảnh nộp cần được ẩn danh.
- Driver GPS từ Flutter: ĐÃ ĐƯỢC NGƯỜI DÙNG QUAN SÁT TRÊN DBeaver Ở GIAI ĐOẠN M2; ảnh nộp cần được ẩn danh.
- Driver Accept end-to-end: CHƯA_XÁC_MINH

Chi tiết từng bảng và diễn giải giới hạn kết quả: [`VERIFIED_SNAPSHOT_2026-10-15.md`](VERIFIED_SNAPSHOT_2026-10-15.md).
