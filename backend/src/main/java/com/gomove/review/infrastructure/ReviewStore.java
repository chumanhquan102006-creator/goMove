package com.gomove.review.infrastructure;

import com.gomove.review.api.RatingResponse;
import com.gomove.review.api.ReputationResponse;
import com.gomove.review.api.RewardEventResponse;
import com.gomove.review.api.RewardHistoryResponse;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.math.BigDecimal;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

@Repository
public class ReviewStore {
    private final JdbcTemplate jdbc;

    public ReviewStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public Optional<RatedBooking> ownedBooking(UUID bookingPublicId, UUID customerPublicId, boolean lock) {
        String sql = """
                SELECT b.id, b.public_id, b.status, b.customer_id, b.assigned_driver_id
                FROM bookings b JOIN users u ON u.id = b.customer_id
                WHERE b.public_id = ? AND u.public_id = ?
                """ + (lock ? " FOR UPDATE OF b" : "");
        return jdbc.query(sql, (rs, row) -> new RatedBooking(
                rs.getLong("id"), rs.getObject("public_id", UUID.class), rs.getString("status"),
                rs.getLong("customer_id"), rs.getObject("assigned_driver_id", Long.class)),
                bookingPublicId, customerPublicId).stream().findFirst();
    }

    public Optional<RatingResponse> rating(Long bookingId) {
        return jdbc.query("""
                SELECT r.public_id, b.public_id AS booking_public_id, r.stars, r.comment, r.created_at
                FROM trip_ratings r JOIN bookings b ON b.id = r.booking_id WHERE r.booking_id = ?
                """, (rs, row) -> rating(rs), bookingId).stream().findFirst();
    }

    public InsertedRating insertRating(RatedBooking booking, int stars, String comment) {
        UUID publicId = UUID.randomUUID();
        return jdbc.query("""
                INSERT INTO trip_ratings (public_id, booking_id, customer_id, driver_id, stars, comment)
                VALUES (?, ?, ?, ?, ?, ?) RETURNING id, created_at
                """, (rs, row) -> new InsertedRating(rs.getLong("id"), publicId,
                booking.publicId(), stars, comment, rs.getTimestamp("created_at").toInstant()),
                publicId, booking.id(), booking.customerId(), booking.driverId(), stars, comment).getFirst();
    }

    public void insertPoints(long ratingId, long driverId, int delta) {
        jdbc.update("""
                INSERT INTO driver_point_events
                    (public_id, rating_id, driver_id, event_type, points_delta, policy_version)
                VALUES (?, ?, ?, 'RATING_REWARD', ?, 'GOPOINTS_MVP_V1')
                """, UUID.randomUUID(), ratingId, driverId, delta);
    }

    public Optional<Long> driverIdForUser(UUID userPublicId) {
        return jdbc.query("""
                SELECT d.id FROM drivers d JOIN users u ON u.id = d.user_id WHERE u.public_id = ?
                """, (rs, row) -> rs.getLong(1), userPublicId).stream().findFirst();
    }

    public void lockDriver(long driverId) {
        jdbc.query("SELECT id FROM drivers WHERE id = ? FOR UPDATE",
                (rs, row) -> rs.getLong(1), driverId);
    }

    public ReputationResponse reputation(long driverId) {
        return jdbc.queryForObject("""
                SELECT (SELECT ROUND(AVG(stars)::numeric, 2) FROM trip_ratings WHERE driver_id = ?) AS average,
                       (SELECT count(*) FROM trip_ratings WHERE driver_id = ?) AS rating_count,
                       (SELECT COALESCE(sum(GREATEST(points_delta, 0)), 0)
                        FROM driver_point_events WHERE driver_id = ?) AS earned,
                       (SELECT COALESCE(sum(GREATEST(-points_delta, 0)), 0)
                        FROM driver_point_events WHERE driver_id = ?) AS deducted
                """, (rs, row) -> {
            long count = rs.getLong("rating_count");
            long earned = rs.getLong("earned");
            long deducted = rs.getLong("deducted");
            List<String> badges = count >= 10 && rs.getBigDecimal("average").compareTo(new BigDecimal("4.50")) >= 0
                    ? List.of("FAVORITE_DRIVER") : List.of();
            return new ReputationResponse(count == 0 ? null : rs.getBigDecimal("average"), count,
                    earned, deducted, Math.max(0, earned - deducted), badges);
        }, driverId, driverId, driverId, driverId);
    }

    public RewardHistoryResponse rewards(long driverId, int page, int size) {
        long total = jdbc.queryForObject("SELECT count(*) FROM driver_point_events WHERE driver_id = ?",
                Long.class, driverId);
        List<RewardEventResponse> items = jdbc.query("""
                SELECT e.public_id, b.public_id AS booking_public_id, r.stars,
                       e.points_delta, e.created_at
                FROM driver_point_events e JOIN trip_ratings r ON r.id = e.rating_id
                JOIN bookings b ON b.id = r.booking_id
                WHERE e.driver_id = ? ORDER BY e.created_at DESC, e.id DESC LIMIT ? OFFSET ?
                """, (rs, row) -> new RewardEventResponse(rs.getObject("public_id", UUID.class),
                rs.getObject("booking_public_id", UUID.class), rs.getInt("stars"),
                rs.getInt("points_delta"), rs.getTimestamp("created_at").toInstant()),
                driverId, size, (long) page * size);
        return new RewardHistoryResponse(items, page, size, total, (long) (page + 1) * size < total);
    }

    public RecentStats recentStats(long driverId, int window) {
        long total = jdbc.queryForObject("SELECT count(*) FROM trip_ratings WHERE driver_id = ?",
                Long.class, driverId);
        BigDecimal average = jdbc.queryForObject("""
                SELECT AVG(stars)::numeric FROM (
                    SELECT stars FROM trip_ratings WHERE driver_id = ?
                    ORDER BY created_at DESC, id DESC LIMIT ?
                ) recent
                """, BigDecimal.class, driverId, window);
        return new RecentStats(total, average);
    }

    public void flagDriver(long driverId, long count, BigDecimal recentAverage,
                           int recentWindow, String reason) {
        jdbc.update("""
                INSERT INTO driver_quality_cases
                    (public_id, driver_id, status, rating_count, recent_average, reason)
                SELECT ?, ?, 'OPEN', ?, ?, ?
                WHERE NOT EXISTS (
                    SELECT 1 FROM driver_quality_cases
                    WHERE driver_id = ? AND (status IN ('OPEN', 'WARNED', 'DISPUTED', 'SUSPENDED')
                        OR ? - rating_count < ?))
                ON CONFLICT (driver_id) WHERE status IN ('OPEN', 'WARNED', 'DISPUTED', 'SUSPENDED') DO NOTHING
                """, UUID.randomUUID(), driverId, count,
                recentAverage.setScale(2, java.math.RoundingMode.HALF_UP), reason,
                driverId, count, recentWindow);
    }

    private static RatingResponse rating(ResultSet rs) throws SQLException {
        return new RatingResponse(rs.getObject("public_id", UUID.class),
                rs.getObject("booking_public_id", UUID.class), rs.getInt("stars"),
                rs.getString("comment"), rs.getTimestamp("created_at").toInstant());
    }

    public record RatedBooking(long id, UUID publicId, String status, long customerId, Long driverId) {}
    public record InsertedRating(long id, UUID publicId, UUID bookingPublicId,
                                 int stars, String comment, Instant createdAt) {
        public RatingResponse response() { return new RatingResponse(publicId, bookingPublicId, stars, comment, createdAt); }
    }
    public record RecentStats(long total, BigDecimal average) {}
}
