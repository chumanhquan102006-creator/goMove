package com.gomove.trip.infrastructure;

import com.gomove.auth.domain.UserRole;
import com.gomove.booking.domain.BookingStatus;
import com.gomove.common.exception.DomainException;
import com.gomove.trip.service.TripAction;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

@Repository
public class TripStore {
    private final JdbcTemplate jdbc;

    public TripStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public Optional<TripBooking> assignedDriverBooking(UUID bookingPublicId, UUID driverUserPublicId, boolean lock) {
        String sql = """
                SELECT b.id, b.status, b.assigned_driver_id, b.assigned_vehicle_id
                FROM bookings b JOIN drivers d ON d.id = b.assigned_driver_id
                JOIN users u ON u.id = d.user_id
                WHERE b.public_id = ? AND u.public_id = ?
                """ + (lock ? " FOR UPDATE OF b" : "");
        return jdbc.query(sql, (rs, row) -> new TripBooking(rs.getLong("id"),
                BookingStatus.valueOf(rs.getString("status")), rs.getLong("assigned_driver_id"),
                rs.getLong("assigned_vehicle_id")), bookingPublicId, driverUserPublicId)
                .stream().findFirst();
    }

    public Instant transition(Long bookingId, TripAction action, Instant now) {
        // Column names are compile-time enum constants, never client input. The row lock and
        // status predicate jointly prevent replay or competing commands from advancing twice.
        String sql = "UPDATE bookings SET status = ?, " + action.timestampColumn() + " = GREATEST(?, "
                + action.previousTimestampColumn() + "), version = version + 1, updated_at = ? "
                + "WHERE id = ? AND status = ? RETURNING " + action.timestampColumn();
        return jdbc.query(sql, (rs, row) -> rs.getTimestamp(1).toInstant(), action.target().name(),
                Timestamp.from(now), Timestamp.from(now), bookingId, action.expected().name())
                .stream().findFirst().orElseThrow(() -> new DomainException(HttpStatus.CONFLICT,
                        "TRIP_STATE_CONFLICT", "Trip state changed concurrently"));
    }

    public Optional<TrackingState> tracking(UUID bookingPublicId, UUID userPublicId, UserRole role) {
        if (role != UserRole.CUSTOMER && role != UserRole.DRIVER) return Optional.empty();
        return jdbc.query("""
                SELECT b.public_id AS booking_public_id, b.status, d.public_id AS driver_public_id,
                       b.driver_accepted_at, b.driver_arrived_at, b.passenger_onboard_at,
                       b.trip_started_at, b.trip_completed_at,
                       ST_Y(dl.current_location::geometry) AS latitude,
                       ST_X(dl.current_location::geometry) AS longitude,
                       dl.accuracy, dl.bearing, dl.updated_at AS location_updated_at
                FROM bookings b JOIN users customer ON customer.id = b.customer_id
                LEFT JOIN drivers d ON d.id = b.assigned_driver_id
                LEFT JOIN users driver_user ON driver_user.id = d.user_id
                LEFT JOIN driver_locations dl ON dl.driver_id = d.id
                    AND b.status IN ('DRIVER_ACCEPTED', 'DRIVER_ARRIVED',
                                     'PASSENGER_ONBOARD', 'IN_PROGRESS')
                WHERE b.public_id = ? AND
                    ((? = 'CUSTOMER' AND customer.public_id = ?) OR
                     (? = 'DRIVER' AND driver_user.public_id = ?))
                """, (rs, row) -> trackingRow(rs), bookingPublicId, role.name(), userPublicId,
                role.name(), userPublicId).stream().findFirst();
    }

    public boolean mayTrack(UUID bookingPublicId, UUID driverUserPublicId) {
        return jdbc.query("""
                SELECT b.status FROM bookings b JOIN drivers d ON d.id = b.assigned_driver_id
                JOIN users u ON u.id = d.user_id WHERE b.public_id = ? AND u.public_id = ?
                """, (rs, row) -> isTrackingStatus(BookingStatus.valueOf(rs.getString(1))),
                bookingPublicId, driverUserPublicId).stream().findFirst().orElse(false);
    }

    public static boolean isTrackingStatus(BookingStatus status) {
        return status == BookingStatus.DRIVER_ACCEPTED || status == BookingStatus.DRIVER_ARRIVED
                || status == BookingStatus.PASSENGER_ONBOARD || status == BookingStatus.IN_PROGRESS;
    }

    private TrackingState trackingRow(ResultSet rs) throws SQLException {
        return new TrackingState(rs.getObject("booking_public_id", UUID.class),
                BookingStatus.valueOf(rs.getString("status")), rs.getObject("driver_public_id", UUID.class),
                instant(rs, "driver_accepted_at"), instant(rs, "driver_arrived_at"),
                instant(rs, "passenger_onboard_at"), instant(rs, "trip_started_at"),
                instant(rs, "trip_completed_at"), rs.getObject("latitude", Double.class),
                rs.getObject("longitude", Double.class), rs.getObject("accuracy", Double.class),
                rs.getObject("bearing", Double.class), instant(rs, "location_updated_at"));
    }

    private Instant instant(ResultSet rs, String name) throws SQLException {
        Timestamp value = rs.getTimestamp(name);
        return value == null ? null : value.toInstant();
    }

    public record TripBooking(Long id, BookingStatus status, Long driverId, Long vehicleId) {}

    public record TrackingState(UUID bookingPublicId, BookingStatus status, UUID driverPublicId,
                                Instant driverAcceptedAt, Instant driverArrivedAt,
                                Instant passengerOnboardAt, Instant tripStartedAt, Instant tripCompletedAt,
                                Double latitude, Double longitude, Double accuracy, Double bearing,
                                Instant locationUpdatedAt) {}
}
