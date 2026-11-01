package com.gomove.booking.infrastructure;

import com.gomove.booking.domain.BookingStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

@Repository
public class BookingCancellationStore {
    private final JdbcTemplate jdbc;

    public BookingCancellationStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public void boundLockWait() { jdbc.execute("SET LOCAL lock_timeout = '5s'"); }

    public Optional<CancellableBooking> lockCustomerBooking(UUID bookingPublicId, UUID customerPublicId) {
        return jdbc.query("""
                SELECT b.id, b.status, b.assigned_driver_id, b.cancelled_at
                FROM bookings b JOIN users u ON u.id = b.customer_id
                WHERE b.public_id = ? AND u.public_id = ? FOR UPDATE OF b
                """, (rs, row) -> new CancellableBooking(rs.getLong("id"),
                BookingStatus.valueOf(rs.getString("status")),
                rs.getObject("assigned_driver_id", Long.class),
                instant(rs.getTimestamp("cancelled_at"))), bookingPublicId, customerPublicId)
                .stream().findFirst();
    }

    public Optional<CancellableBooking> lockDriverBooking(UUID bookingPublicId, UUID driverUserPublicId) {
        return jdbc.query("""
                SELECT b.id, b.status, b.assigned_driver_id, b.cancelled_at
                FROM bookings b JOIN drivers d ON d.id = b.assigned_driver_id
                JOIN users u ON u.id = d.user_id
                WHERE b.public_id = ? AND u.public_id = ? FOR UPDATE OF b
                """, (rs, row) -> new CancellableBooking(rs.getLong("id"),
                BookingStatus.valueOf(rs.getString("status")),
                rs.getObject("assigned_driver_id", Long.class),
                instant(rs.getTimestamp("cancelled_at"))), bookingPublicId, driverUserPublicId)
                .stream().findFirst();
    }

    public boolean lockAssignedDriver(long driverId) {
        return !jdbc.query("SELECT id FROM drivers WHERE id = ? FOR UPDATE",
                (rs, row) -> rs.getLong(1), driverId).isEmpty();
    }

    public Instant cancel(long bookingId, String actor, Instant requestedAt) {
        return jdbc.query("""
                UPDATE bookings SET status = 'CANCELLED',
                    cancelled_at = GREATEST(?, created_at, driver_accepted_at, driver_arrived_at),
                    cancelled_by = ?,
                    driver_released_at = CASE WHEN assigned_driver_id IS NULL THEN NULL
                        ELSE GREATEST(?, created_at, driver_accepted_at, driver_arrived_at) END,
                    version = version + 1, updated_at = ?
                WHERE id = ? AND status IN
                    ('REQUESTED', 'SEARCHING_DRIVER', 'DRIVER_ACCEPTED', 'DRIVER_ARRIVED')
                RETURNING cancelled_at
                """, (rs, row) -> instant(rs.getTimestamp(1)), ts(requestedAt), actor,
                ts(requestedAt), ts(requestedAt), bookingId).stream().findFirst().orElse(null);
    }

    public int cancelPendingOffer(long bookingId, Instant at) {
        return jdbc.update("""
                UPDATE booking_driver_offers SET status = 'CANCELLED', responded_at = ?,
                    updated_at = ?, version = version + 1
                WHERE booking_id = ? AND status = 'PENDING'
                """, ts(at), ts(at), bookingId);
    }

    public int releaseDriver(long driverId, Instant at) {
        return jdbc.update("""
                UPDATE drivers SET operating_status = CASE
                        WHEN approval_status = 'APPROVED' THEN 'ONLINE' ELSE 'OFFLINE' END,
                    updated_at = ?, version = version + 1
                WHERE id = ? AND operating_status = 'BUSY'
                  AND NOT EXISTS (SELECT 1 FROM bookings b
                                  WHERE b.assigned_driver_id = ? AND b.driver_released_at IS NULL)
                """, ts(at), driverId, driverId);
    }

    private static Instant instant(Timestamp value) { return value == null ? null : value.toInstant(); }
    private static Timestamp ts(Instant value) { return Timestamp.from(value); }

    public record CancellableBooking(long id, BookingStatus status, Long driverId, Instant cancelledAt) {}
}
