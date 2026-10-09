package com.gomove.booking.service;

import com.gomove.common.exception.DomainException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public class BookingIdempotencyStore {
    private final JdbcTemplate jdbc;

    public BookingIdempotencyStore(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public void boundLockWait() {
        // This applies only to the current PostgreSQL transaction and rolls back with it.
        jdbc.execute("SET LOCAL lock_timeout = '5s'");
    }

    public Long claim(Long customerId, String key, String requestHash) {
        List<Long> inserted = jdbc.query("""
                INSERT INTO booking_idempotency (customer_id, idempotency_key, request_hash)
                VALUES (?, ?, ?)
                ON CONFLICT (customer_id, idempotency_key) DO NOTHING
                RETURNING id
                """, (rs, rowNum) -> rs.getLong(1), customerId, key, requestHash);
        return inserted.isEmpty() ? null : inserted.get(0);
    }

    public StoredOutcome existing(Long customerId, String key) {
        return jdbc.query("""
                SELECT request_hash, http_status, response_body::text
                FROM booking_idempotency
                WHERE customer_id = ? AND idempotency_key = ?
                """, (rs, rowNum) -> new StoredOutcome(rs.getString(1),
                        rs.getObject(2, Integer.class), rs.getString(3)), customerId, key)
                .stream().findFirst()
                .orElseThrow(() -> new IllegalStateException("Conflicting idempotency key was not found"));
    }

    public String finish(Long claimId, Long bookingId, String responseJson) {
        int changed = jdbc.update("""
                UPDATE booking_idempotency
                SET booking_id = ?, http_status = 201, response_body = CAST(? AS jsonb)
                WHERE id = ? AND booking_id IS NULL
                """, bookingId, responseJson, claimId);
        if (changed != 1) throw new IllegalStateException("Booking outcome was not stored");
        return jdbc.queryForObject("SELECT response_body::text FROM booking_idempotency WHERE id = ?",
                String.class, claimId);
    }

    public record StoredOutcome(String requestHash, Integer httpStatus, String responseBody) {
        public BookingResult replay(String expectedHash) {
            if (!requestHash.equals(expectedHash)) {
                throw new DomainException(HttpStatus.CONFLICT, "IDEMPOTENCY_KEY_REUSED",
                        "Idempotency-Key was used for a different Booking request");
            }
            if (httpStatus == null || responseBody == null) {
                throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "BOOKING_IN_PROGRESS",
                        "Booking outcome is not yet available");
            }
            return new BookingResult(httpStatus, responseBody);
        }
    }
}
