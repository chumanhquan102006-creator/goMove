package com.gomove.admin.infrastructure;

import com.gomove.admin.api.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

@Repository
public class AdminQueryStore {
    private final JdbcTemplate jdbc;

    public AdminQueryStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public AdminPage<AdminDriver> drivers(String approval, String search, int page, int size) {
        String filter = """
                FROM drivers d JOIN users u ON u.id = d.user_id
                WHERE (CAST(? AS VARCHAR) IS NULL OR d.approval_status = ?)
                  AND (CAST(? AS VARCHAR) IS NULL OR u.full_name ILIKE ? OR u.phone ILIKE ?
                       OR d.license_number ILIKE ? OR d.public_id::text = ?)
                """;
        String like = search == null ? null : "%" + search + "%";
        Object[] args = {approval, approval, search, like, like, like, search};
        long total = jdbc.queryForObject("SELECT count(*) " + filter, Long.class, args);
        List<AdminDriver> items = jdbc.query("""
                SELECT d.public_id, u.public_id AS user_public_id, u.full_name, u.phone,
                       d.license_number, d.approval_status, d.operating_status,
                       d.total_trips, d.created_at,
                       (SELECT ROUND(AVG(stars)::numeric, 2) FROM trip_ratings
                        WHERE driver_id = d.id) AS rating_average,
                       (SELECT count(*) FROM trip_ratings WHERE driver_id = d.id) AS rating_count,
                       GREATEST(0, COALESCE((SELECT sum(points_delta) FROM driver_point_events
                        WHERE driver_id = d.id), 0)) AS available_points,
                       EXISTS (SELECT 1 FROM driver_quality_cases q WHERE q.driver_id = d.id
                           AND q.status IN ('OPEN', 'WARNED', 'DISPUTED')) AS quality_flagged,
                       EXISTS (SELECT 1 FROM bookings b WHERE b.assigned_driver_id = d.id
                               AND b.driver_released_at IS NULL) AS unreleased_booking
                """ + filter + " ORDER BY d.created_at DESC, d.id DESC LIMIT ? OFFSET ?",
                (rs, row) -> driver(rs, List.of()), append(args, size, (long) page * size));
        return new AdminPage<>(items, page, size, total);
    }

    public Optional<AdminDriver> driver(UUID publicId) {
        return jdbc.query("""
                SELECT d.id, d.public_id, u.public_id AS user_public_id, u.full_name, u.phone,
                       d.license_number, d.approval_status, d.operating_status,
                       d.total_trips, d.created_at,
                       (SELECT ROUND(AVG(stars)::numeric, 2) FROM trip_ratings
                        WHERE driver_id = d.id) AS rating_average,
                       (SELECT count(*) FROM trip_ratings WHERE driver_id = d.id) AS rating_count,
                       GREATEST(0, COALESCE((SELECT sum(points_delta) FROM driver_point_events
                        WHERE driver_id = d.id), 0)) AS available_points,
                       EXISTS (SELECT 1 FROM driver_quality_cases q WHERE q.driver_id = d.id
                           AND q.status IN ('OPEN', 'WARNED', 'DISPUTED')) AS quality_flagged,
                       EXISTS (SELECT 1 FROM bookings b WHERE b.assigned_driver_id = d.id
                               AND b.driver_released_at IS NULL) AS unreleased_booking
                FROM drivers d JOIN users u ON u.id = d.user_id WHERE d.public_id = ?
                """, (rs, row) -> driver(rs, jdbc.query("""
                        SELECT public_id, license_plate, vehicle_type, brand, model, color, is_active
                        FROM vehicles WHERE driver_id = ? ORDER BY created_at DESC, id DESC
                        """, (v, ignored) -> new AdminVehicle(v.getObject("public_id", UUID.class),
                        v.getString("license_plate"), v.getString("vehicle_type"),
                        v.getString("brand"), v.getString("model"), v.getString("color"),
                        v.getBoolean("is_active")), rs.getLong("id"))), publicId).stream().findFirst();
    }

    private static AdminDriver driver(ResultSet rs, List<AdminVehicle> vehicles) throws SQLException {
        return new AdminDriver(rs.getObject("public_id", UUID.class),
                rs.getObject("user_public_id", UUID.class), rs.getString("full_name"),
                rs.getString("phone"), rs.getString("license_number"),
                rs.getString("approval_status"), rs.getString("operating_status"),
                rs.getInt("total_trips"), rs.getBoolean("unreleased_booking"),
                instant(rs.getTimestamp("created_at")), vehicles,
                rs.getBigDecimal("rating_average"), rs.getLong("rating_count"),
                rs.getLong("available_points"), rs.getBoolean("quality_flagged"));
    }

    private static final String ACCOUNT_FROM = """
            FROM users u LEFT JOIN drivers d ON d.user_id = u.id
            WHERE (CAST(? AS VARCHAR) IS NULL OR u.role = ?)
              AND (CAST(? AS VARCHAR) IS NULL OR u.full_name ILIKE ? OR u.phone ILIKE ?
                   OR u.email ILIKE ? OR u.public_id::text = ?)
            """;
    private static final String ACCOUNT_COLUMNS = """
            SELECT u.public_id, u.full_name, u.phone, u.email, u.role, u.status,
                   u.created_at, d.public_id AS driver_public_id,
                   d.approval_status, d.operating_status,
                   EXISTS (SELECT 1 FROM bookings b WHERE
                       (b.customer_id = u.id OR b.assigned_driver_id = d.id)
                       AND b.status NOT IN ('COMPLETED', 'CANCELLED', 'NO_DRIVER_AVAILABLE'))
                       AS active_booking,
                   (SELECT max(b.created_at) FROM bookings b WHERE
                       b.customer_id = u.id OR b.assigned_driver_id = d.id) AS last_booking_at
            """;

    public AdminPage<AdminAccount> accounts(String role, String search, int page, int size) {
        String like = search == null ? null : "%" + search + "%";
        Object[] args = {role, role, search, like, like, like, search};
        long total = jdbc.queryForObject("SELECT count(*) " + ACCOUNT_FROM, Long.class, args);
        List<AdminAccount> items = jdbc.query(ACCOUNT_COLUMNS + ACCOUNT_FROM
                + " ORDER BY u.created_at DESC, u.id DESC LIMIT ? OFFSET ?",
                (rs, row) -> account(rs), append(args, size, (long) page * size));
        return new AdminPage<>(items, page, size, total);
    }

    public Optional<AdminAccount> account(UUID publicId) {
        return jdbc.query(ACCOUNT_COLUMNS + " FROM users u LEFT JOIN drivers d ON d.user_id = u.id"
                + " WHERE u.public_id = ?", (rs, row) -> account(rs), publicId).stream().findFirst();
    }

    private static AdminAccount account(ResultSet rs) throws SQLException {
        return new AdminAccount(rs.getObject("public_id", UUID.class), rs.getString("full_name"),
                rs.getString("phone"), rs.getString("email"), rs.getString("role"),
                rs.getString("status"), rs.getObject("driver_public_id", UUID.class),
                rs.getString("approval_status"), rs.getString("operating_status"),
                rs.getBoolean("active_booking"), instant(rs.getTimestamp("last_booking_at")),
                instant(rs.getTimestamp("created_at")));
    }

    public AdminPage<AdminBooking> bookings(String status, int page, int size) {
        String from = """
                FROM bookings b JOIN users customer ON customer.id = b.customer_id
                LEFT JOIN drivers d ON d.id = b.assigned_driver_id
                LEFT JOIN cash_payments p ON p.booking_id = b.id
                WHERE (CAST(? AS VARCHAR) IS NULL OR b.status = ?)
                """;
        long total = jdbc.queryForObject("SELECT count(*) " + from, Long.class, status, status);
        List<AdminBooking> items = jdbc.query("""
                SELECT b.public_id, customer.public_id AS customer_public_id,
                       d.public_id AS driver_public_id, b.status, b.vehicle_type,
                       b.final_fare, b.currency_code, p.status AS cash_status, b.created_at
                """ + from + " ORDER BY b.created_at DESC, b.id DESC LIMIT ? OFFSET ?",
                (rs, row) -> new AdminBooking(rs.getObject("public_id", UUID.class),
                        rs.getObject("customer_public_id", UUID.class),
                        rs.getObject("driver_public_id", UUID.class), rs.getString("status"),
                        rs.getString("vehicle_type"), rs.getBigDecimal("final_fare"),
                        rs.getString("currency_code"), rs.getString("cash_status"),
                        instant(rs.getTimestamp("created_at"))), status, status, size, (long) page * size);
        return new AdminPage<>(items, page, size, total);
    }

    public AdminDashboard dashboard() {
        var users = jdbc.queryForMap("""
                SELECT count(*) FILTER (WHERE role = 'CUSTOMER') AS customers
                FROM users
                """);
        var drivers = jdbc.queryForMap("""
                SELECT count(*) AS drivers,
                       count(*) FILTER (WHERE approval_status = 'PENDING') AS pending,
                       count(*) FILTER (WHERE operating_status = 'ONLINE') AS online,
                       count(*) FILTER (WHERE operating_status = 'OFFLINE') AS offline,
                       count(*) FILTER (WHERE operating_status = 'BUSY') AS busy
                FROM drivers
                """);
        var bookings = jdbc.queryForMap("""
                SELECT count(*) FILTER (WHERE status NOT IN
                           ('COMPLETED', 'CANCELLED', 'NO_DRIVER_AVAILABLE')) AS active,
                       count(*) FILTER (WHERE status = 'COMPLETED') AS completed,
                       count(*) FILTER (WHERE status = 'CANCELLED') AS cancelled,
                       count(*) FILTER (WHERE status = 'NO_DRIVER_AVAILABLE') AS no_driver
                FROM bookings
                """);
        var cash = jdbc.queryForMap("""
                SELECT count(*) FILTER (WHERE p.status = 'PAID') AS paid,
                       count(*) FILTER (WHERE p.status = 'PENDING' AND b.status = 'COMPLETED') AS collectible,
                       COALESCE(sum(p.amount) FILTER (WHERE p.status = 'PENDING'
                           AND b.status = 'COMPLETED'), 0) AS collectible_amount,
                       count(*) FILTER (WHERE p.status = 'VOID') AS void_count,
                       COALESCE(sum(p.amount) FILTER (WHERE p.status = 'VOID'), 0) AS void_amount
                FROM cash_payments p JOIN bookings b ON b.id = p.booking_id
                """);
        var quality = jdbc.queryForMap("""
                SELECT (SELECT count(*) FROM trip_ratings) AS rated_trips,
                       (SELECT count(*) FROM driver_quality_cases
                        WHERE status IN ('OPEN', 'WARNED', 'DISPUTED')) AS flagged_drivers,
                       (SELECT COALESCE(sum(GREATEST(points_delta, 0)), 0)
                        FROM driver_point_events) AS points_awarded,
                       (SELECT COALESCE(sum(GREATEST(-points_delta, 0)), 0)
                        FROM driver_point_events) AS points_deducted
                """);
        return new AdminDashboard(number(users, "customers"), number(drivers, "drivers"),
                number(drivers, "pending"), number(drivers, "online"), number(drivers, "offline"),
                number(drivers, "busy"), number(bookings, "active"), number(bookings, "completed"),
                number(bookings, "cancelled"), number(bookings, "no_driver"), number(cash, "paid"),
                number(cash, "collectible"), (java.math.BigDecimal) cash.get("collectible_amount"),
                number(cash, "void_count"), (java.math.BigDecimal) cash.get("void_amount"),
                number(quality, "rated_trips"), number(quality, "flagged_drivers"),
                number(quality, "points_awarded"), number(quality, "points_deducted"));
    }

    private static long number(java.util.Map<String, Object> row, String key) {
        return ((Number) row.get(key)).longValue();
    }

    private static Object[] append(Object[] values, Object... extra) {
        Object[] result = java.util.Arrays.copyOf(values, values.length + extra.length);
        System.arraycopy(extra, 0, result, values.length, extra.length);
        return result;
    }

    private static Instant instant(Timestamp value) { return value == null ? null : value.toInstant(); }
}
