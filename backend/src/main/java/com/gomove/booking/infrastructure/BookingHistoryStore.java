package com.gomove.booking.infrastructure;

import com.gomove.booking.api.BookingHistoryItemResponse;
import com.gomove.booking.domain.BookingStatus;
import com.gomove.vehicle.domain.VehicleType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.UUID;

@Repository
public class BookingHistoryStore {
    private final JdbcTemplate jdbc;

    public BookingHistoryStore(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public long countCompleted(UUID customerPublicId) {
        return jdbc.queryForObject("""
                SELECT count(*) FROM bookings b
                JOIN users u ON u.id = b.customer_id
                WHERE u.public_id = ? AND b.status = 'COMPLETED'
                """, Long.class, customerPublicId);
    }

    public List<BookingHistoryItemResponse> completed(UUID customerPublicId, int size, long offset) {
        return jdbc.query("""
                SELECT b.public_id, b.created_at, b.trip_completed_at,
                       ST_Y(b.pickup_location::geometry) AS pickup_latitude,
                       ST_X(b.pickup_location::geometry) AS pickup_longitude,
                       ST_Y(b.dropoff_location::geometry) AS dropoff_latitude,
                       ST_X(b.dropoff_location::geometry) AS dropoff_longitude,
                       b.vehicle_type, b.final_fare, b.currency_code, b.status,
                       p.status AS payment_status
                FROM bookings b
                JOIN users u ON u.id = b.customer_id
                LEFT JOIN cash_payments p ON p.booking_id = b.id
                WHERE u.public_id = ? AND b.status = 'COMPLETED'
                ORDER BY b.trip_completed_at DESC, b.id DESC
                LIMIT ? OFFSET ?
                """, (rs, row) -> new BookingHistoryItemResponse(
                rs.getObject("public_id", UUID.class),
                rs.getTimestamp("created_at").toInstant(),
                rs.getTimestamp("trip_completed_at").toInstant(),
                rs.getDouble("pickup_latitude"), rs.getDouble("pickup_longitude"),
                rs.getDouble("dropoff_latitude"), rs.getDouble("dropoff_longitude"),
                VehicleType.valueOf(rs.getString("vehicle_type")),
                rs.getBigDecimal("final_fare"), rs.getString("currency_code"),
                BookingStatus.valueOf(rs.getString("status")),
                rs.getString("payment_status")), customerPublicId, size, offset);
    }
}
