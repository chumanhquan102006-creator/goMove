package com.gomove.dispatch.infrastructure;

import com.gomove.booking.domain.BookingStatus;
import com.gomove.dispatch.domain.DriverOfferStatus;
import com.gomove.driver.domain.DriverApprovalStatus;
import com.gomove.driver.domain.DriverOperatingStatus;
import com.gomove.vehicle.domain.VehicleType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.math.BigDecimal;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

@Repository
public class DispatchStore {
    private final JdbcTemplate jdbc;

    public DispatchStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public void boundLockWait() { jdbc.execute("SET LOCAL lock_timeout = '5s'"); }

    public List<Long> dueBookings(Instant now, int limit) {
        return jdbc.query("""
                SELECT id FROM bookings
                WHERE status IN ('REQUESTED', 'SEARCHING_DRIVER') AND next_dispatch_at <= ?
                ORDER BY next_dispatch_at, id LIMIT ?
                """, (rs, row) -> rs.getLong(1), ts(now), limit);
    }

    public Optional<DispatchBooking> lockBooking(Long id) {
        return jdbc.query("""
                SELECT id, status, vehicle_type, assigned_driver_id, assigned_vehicle_id
                FROM bookings WHERE id = ? FOR UPDATE SKIP LOCKED
                """, (rs, row) -> new DispatchBooking(rs.getLong("id"),
                        BookingStatus.valueOf(rs.getString("status")),
                        VehicleType.valueOf(rs.getString("vehicle_type")),
                        rs.getObject("assigned_driver_id", Long.class),
                        rs.getObject("assigned_vehicle_id", Long.class)), id)
                .stream().findFirst();
    }

    public Optional<DispatchBooking> lockBookingForAcceptance(Long id) {
        return jdbc.query("""
                SELECT id, status, vehicle_type, assigned_driver_id, assigned_vehicle_id
                FROM bookings WHERE id = ? FOR UPDATE
                """, (rs, row) -> new DispatchBooking(rs.getLong("id"),
                        BookingStatus.valueOf(rs.getString("status")),
                        VehicleType.valueOf(rs.getString("vehicle_type")),
                        rs.getObject("assigned_driver_id", Long.class),
                        rs.getObject("assigned_vehicle_id", Long.class)), id)
                .stream().findFirst();
    }

    public Optional<Offer> pendingForBooking(Long bookingId) {
        return jdbc.query("""
                SELECT id, booking_id, driver_id, vehicle_id, status, offered_at, expires_at
                FROM booking_driver_offers WHERE booking_id = ? AND status = 'PENDING'
                """, (rs, row) -> offer(rs), bookingId).stream().findFirst();
    }

    public Optional<Candidate> nearestCandidate(Long bookingId, Instant freshnessCutoff, double radiusMeters) {
        return jdbc.query("""
                SELECT d.id AS driver_id, v.id AS vehicle_id
                FROM bookings b
                JOIN driver_locations dl ON ST_DWithin(dl.current_location, b.pickup_location, ?)
                JOIN drivers d ON d.id = dl.driver_id
                JOIN vehicles v ON v.driver_id = d.id AND v.is_active = TRUE
                WHERE b.id = ? AND d.approval_status = 'APPROVED'
                  AND d.operating_status = 'ONLINE'
                  AND v.vehicle_type = b.vehicle_type
                  AND dl.updated_at >= ?
                  AND NOT EXISTS (
                      SELECT 1 FROM booking_driver_offers previous
                      WHERE previous.booking_id = b.id AND previous.driver_id = d.id
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM booking_driver_offers pending
                      WHERE pending.driver_id = d.id AND pending.status = 'PENDING'
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM bookings assigned
                      WHERE assigned.assigned_driver_id = d.id AND assigned.driver_released_at IS NULL
                  )
                ORDER BY ST_Distance(dl.current_location, b.pickup_location), d.id
                LIMIT 1 FOR UPDATE OF d SKIP LOCKED
                """, (rs, row) -> new Candidate(rs.getLong("driver_id"), rs.getLong("vehicle_id")),
                radiusMeters, bookingId, ts(freshnessCutoff)).stream().findFirst();
    }

    public boolean createOffer(Long bookingId, Candidate candidate, Instant offeredAt) {
        // The unique indexes arbitrate races against a candidate query's READ COMMITTED snapshot.
        return !jdbc.query("""
                INSERT INTO booking_driver_offers
                    (public_id, booking_id, driver_id, vehicle_id, status, offered_at, expires_at)
                VALUES (?, ?, ?, ?, 'PENDING', ?, ?)
                ON CONFLICT DO NOTHING RETURNING id
                """, (rs, row) -> rs.getLong(1), UUID.randomUUID(), bookingId,
                candidate.driverId(), candidate.vehicleId(),
                ts(offeredAt), ts(offeredAt.plusSeconds(15))).isEmpty();
    }

    public int scheduleSearch(Long bookingId, Instant next, Instant now) {
        return jdbc.update("""
                UPDATE bookings SET status = 'SEARCHING_DRIVER', next_dispatch_at = ?,
                    version = version + 1, updated_at = ?
                WHERE id = ? AND status IN ('REQUESTED', 'SEARCHING_DRIVER')
                  AND assigned_driver_id IS NULL AND assigned_vehicle_id IS NULL
                """, ts(next), ts(now), bookingId);
    }

    public int reschedule(Long bookingId, Instant next, Instant now) {
        return jdbc.update("""
                UPDATE bookings SET next_dispatch_at = ?, version = version + 1, updated_at = ?
                WHERE id = ? AND status = 'SEARCHING_DRIVER'
                """, ts(next), ts(now), bookingId);
    }

    public int finishOffer(Long offerId, DriverOfferStatus status, Instant now) {
        return jdbc.update("""
                UPDATE booking_driver_offers SET status = ?, responded_at = ?,
                    version = version + 1, updated_at = ?
                WHERE id = ? AND status = 'PENDING'
                """, status.name(), ts(now), ts(now), offerId);
    }

    public int finishValidOffer(Long offerId, DriverOfferStatus status, Instant now) {
        return jdbc.update("""
                UPDATE booking_driver_offers SET status = ?, responded_at = ?,
                    version = version + 1, updated_at = ?
                WHERE id = ? AND status = 'PENDING' AND expires_at > ?
                """, status.name(), ts(now), ts(now), offerId, ts(now));
    }

    public Optional<Offer> ownedOffer(UUID offerPublicId, UUID driverUserPublicId) {
        return jdbc.query("""
                SELECT o.id, o.booking_id, o.driver_id, o.vehicle_id, o.status,
                       o.offered_at, o.expires_at
                FROM booking_driver_offers o
                JOIN drivers d ON d.id = o.driver_id
                JOIN users u ON u.id = d.user_id
                WHERE o.public_id = ? AND u.public_id = ?
                """, (rs, row) -> offer(rs), offerPublicId, driverUserPublicId)
                .stream().findFirst();
    }

    public Optional<Offer> lockOffer(Long offerId) {
        return jdbc.query("""
                SELECT id, booking_id, driver_id, vehicle_id, status, offered_at, expires_at
                FROM booking_driver_offers WHERE id = ? FOR UPDATE
                """, (rs, row) -> offer(rs), offerId).stream().findFirst();
    }

    public Optional<DriverState> lockDriver(Long driverId) {
        return jdbc.query("""
                SELECT approval_status, operating_status FROM drivers WHERE id = ? FOR UPDATE
                """, (rs, row) -> new DriverState(
                        DriverApprovalStatus.valueOf(rs.getString(1)),
                        DriverOperatingStatus.valueOf(rs.getString(2))), driverId)
                .stream().findFirst();
    }

    public Optional<VehicleState> lockVehicle(Long vehicleId) {
        return jdbc.query("""
                SELECT driver_id, vehicle_type, is_active FROM vehicles WHERE id = ? FOR UPDATE
                """, (rs, row) -> new VehicleState(rs.getLong(1),
                        VehicleType.valueOf(rs.getString(2)), rs.getBoolean(3)), vehicleId)
                .stream().findFirst();
    }

    public boolean hasActiveAssignment(Long driverId) {
        return Boolean.TRUE.equals(jdbc.queryForObject("""
                SELECT EXISTS (SELECT 1 FROM bookings
                               WHERE assigned_driver_id = ? AND driver_released_at IS NULL)
                """, Boolean.class, driverId));
    }

    public int assignBooking(Long bookingId, Long driverId, Long vehicleId, Instant now) {
        return jdbc.update("""
                UPDATE bookings SET status = 'DRIVER_ACCEPTED', assigned_driver_id = ?,
                    assigned_vehicle_id = ?, driver_accepted_at = ?, version = version + 1,
                    updated_at = ?
                WHERE id = ? AND status = 'SEARCHING_DRIVER'
                  AND assigned_driver_id IS NULL AND assigned_vehicle_id IS NULL
                """, driverId, vehicleId, ts(now), ts(now), bookingId);
    }

    public int makeDriverBusy(Long driverId, Instant now) {
        return jdbc.update("""
                UPDATE drivers SET operating_status = 'BUSY', version = version + 1,
                    updated_at = ?
                WHERE id = ? AND approval_status = 'APPROVED' AND operating_status = 'ONLINE'
                """, ts(now), driverId);
    }

    public List<ActiveOffer> activeOffers(UUID driverUserPublicId, Instant now) {
        return jdbc.query("""
                SELECT o.public_id AS offer_public_id, b.public_id AS booking_public_id,
                       ST_Y(b.pickup_location::geometry) AS pickup_latitude,
                       ST_X(b.pickup_location::geometry) AS pickup_longitude,
                       ST_Y(b.dropoff_location::geometry) AS dropoff_latitude,
                       ST_X(b.dropoff_location::geometry) AS dropoff_longitude,
                       b.vehicle_type, b.currency_code, b.final_fare,
                       o.offered_at, o.expires_at
                FROM booking_driver_offers o
                JOIN bookings b ON b.id = o.booking_id
                JOIN drivers d ON d.id = o.driver_id
                JOIN users u ON u.id = d.user_id
                WHERE u.public_id = ? AND o.status = 'PENDING'
                  AND o.expires_at > ? AND b.status = 'SEARCHING_DRIVER'
                ORDER BY o.offered_at
                """, (rs, row) -> new ActiveOffer(
                        rs.getObject("offer_public_id", UUID.class),
                        rs.getObject("booking_public_id", UUID.class),
                        rs.getDouble("pickup_latitude"), rs.getDouble("pickup_longitude"),
                        rs.getDouble("dropoff_latitude"), rs.getDouble("dropoff_longitude"),
                        VehicleType.valueOf(rs.getString("vehicle_type")),
                        rs.getString("currency_code"), rs.getBigDecimal("final_fare"),
                        instant(rs, "offered_at"), instant(rs, "expires_at")),
                driverUserPublicId, ts(now));
    }

    private Offer offer(ResultSet rs) throws SQLException {
        return new Offer(rs.getLong("id"), rs.getLong("booking_id"), rs.getLong("driver_id"),
                rs.getLong("vehicle_id"), DriverOfferStatus.valueOf(rs.getString("status")),
                instant(rs, "offered_at"), instant(rs, "expires_at"));
    }

    private Instant instant(ResultSet rs, String column) throws SQLException {
        return rs.getTimestamp(column).toInstant();
    }

    private Timestamp ts(Instant instant) { return Timestamp.from(instant); }

    public record DispatchBooking(Long id, BookingStatus status, VehicleType vehicleType,
                                  Long assignedDriverId, Long assignedVehicleId) {}
    public record Candidate(Long driverId, Long vehicleId) {}
    public record Offer(Long id, Long bookingId, Long driverId, Long vehicleId,
                        DriverOfferStatus status, Instant offeredAt, Instant expiresAt) {}
    public record DriverState(DriverApprovalStatus approval, DriverOperatingStatus operating) {}
    public record VehicleState(Long driverId, VehicleType type, boolean active) {}
    public record ActiveOffer(UUID offerPublicId, UUID bookingPublicId,
                              double pickupLatitude, double pickupLongitude,
                              double dropoffLatitude, double dropoffLongitude,
                              VehicleType vehicleType, String currency, BigDecimal finalFare,
                              Instant offeredAt, Instant expiresAt) {}
}
