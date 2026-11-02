package com.gomove.review.infrastructure;

import com.gomove.review.api.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

@Repository
public class QualityStore {
    private static final String COLUMNS = """
            SELECT q.id, q.driver_id, q.public_id, d.public_id AS driver_public_id,
                   u.full_name AS driver_display_name,
                   q.status, q.rating_count, q.recent_average, q.reason,
                   q.created_at, q.updated_at
            FROM driver_quality_cases q JOIN drivers d ON d.id = q.driver_id
            JOIN users u ON u.id = d.user_id
            """;

    private final JdbcTemplate jdbc;

    public QualityStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public Optional<CaseRow> find(UUID publicId, boolean lock) {
        return jdbc.query(COLUMNS + " WHERE q.public_id = ?" + (lock ? " FOR UPDATE OF q" : ""),
                (rs, row) -> caseRow(rs), publicId).stream().findFirst();
    }

    public QualityCasePageResponse page(String status, Long driverId, int page, int size) {
        String filter = " WHERE (?::varchar IS NULL OR q.status = ?) AND (?::bigint IS NULL OR q.driver_id = ?)";
        long total = jdbc.queryForObject("SELECT count(*) FROM driver_quality_cases q" + filter,
                Long.class, status, status, driverId, driverId);
        List<QualityCaseResponse> items = jdbc.query(COLUMNS + filter
                        + " ORDER BY q.created_at DESC, q.id DESC LIMIT ? OFFSET ?",
                (rs, row) -> caseRow(rs).response(), status, status, driverId, driverId,
                size, (long) page * size);
        return new QualityCasePageResponse(items, page, size, total, (long) (page + 1) * size < total);
    }

    public QualityCaseDetailResponse detail(CaseRow row) {
        List<QualityRatingEvidence> evidence = jdbc.query("""
                SELECT b.public_id AS booking_public_id, r.stars, r.comment, r.created_at
                FROM trip_ratings r JOIN bookings b ON b.id = r.booking_id
                WHERE r.driver_id = ? AND r.created_at <= ?
                ORDER BY r.created_at DESC, r.id DESC LIMIT 100
                """, (rs, ignored) -> new QualityRatingEvidence(
                rs.getObject("booking_public_id", UUID.class), rs.getInt("stars"),
                rs.getString("comment"), rs.getTimestamp("created_at").toInstant()),
                row.driverId(), java.sql.Timestamp.from(row.response().createdAt()));
        List<QualityActionResponse> actions = jdbc.query("""
                SELECT public_id, action, note, created_at FROM driver_quality_case_actions
                WHERE case_id = ? ORDER BY created_at DESC, id DESC LIMIT 50
                """, (rs, ignored) -> new QualityActionResponse(rs.getObject("public_id", UUID.class),
                rs.getString("action"), rs.getString("note"),
                rs.getTimestamp("created_at").toInstant()), row.id());
        return new QualityCaseDetailResponse(row.response(), evidence, actions);
    }

    public void transition(CaseRow row, String status, UUID actorPublicId, String action, String note) {
        jdbc.update("UPDATE driver_quality_cases SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
                status, row.id());
        int recorded = jdbc.update("""
                INSERT INTO driver_quality_case_actions
                    (public_id, case_id, actor_user_id, action, note)
                SELECT ?, ?, u.id, ?, ? FROM users u WHERE u.public_id = ?
                """, UUID.randomUUID(), row.id(), action, note, actorPublicId);
        if (recorded != 1) throw new IllegalStateException("Quality actor was not found");
    }

    private static CaseRow caseRow(ResultSet rs) throws SQLException {
        return new CaseRow(rs.getLong("id"), rs.getLong("driver_id"),
                new QualityCaseResponse(rs.getObject("public_id", UUID.class),
                        rs.getObject("driver_public_id", UUID.class),
                        rs.getString("driver_display_name"), rs.getString("status"),
                        rs.getLong("rating_count"), rs.getBigDecimal("recent_average"),
                        rs.getString("reason"), rs.getTimestamp("created_at").toInstant(),
                        rs.getTimestamp("updated_at").toInstant()));
    }

    public record CaseRow(long id, long driverId, QualityCaseResponse response) {}
}
