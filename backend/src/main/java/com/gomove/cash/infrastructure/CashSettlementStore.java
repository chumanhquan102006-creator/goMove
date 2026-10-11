package com.gomove.cash.infrastructure;

import com.gomove.cash.api.CashPaymentResponse;
import com.gomove.cash.api.CashReceiptResponse;
import com.gomove.cash.api.CommissionSummaryResponse;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

@Repository
public class CashSettlementStore {
    private final JdbcTemplate jdbc;

    public CashSettlementStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public void boundLockWait() { jdbc.execute("SET LOCAL lock_timeout = '5s'"); }

    public void initializePayment(long bookingId, BigDecimal fare, String currency) {
        jdbc.update("""
                INSERT INTO cash_payments (public_id, booking_id, method, status, amount, currency_code)
                VALUES (?, ?, 'CASH', 'PENDING', ?, ?)
                """, UUID.randomUUID(), bookingId, fare, currency);
    }

    public Optional<SettlementBooking> lockAssignedBooking(UUID bookingPublicId, UUID driverUserPublicId) {
        return jdbc.query("""
                SELECT b.id, b.public_id, b.status, b.assigned_driver_id, b.final_fare,
                       b.currency_code, b.trip_completed_at, b.driver_released_at
                FROM bookings b
                JOIN drivers d ON d.id = b.assigned_driver_id
                JOIN users u ON u.id = d.user_id
                WHERE b.public_id = ? AND u.public_id = ?
                FOR UPDATE OF b
                """, (rs, row) -> new SettlementBooking(rs.getLong("id"),
                        rs.getObject("public_id", UUID.class), rs.getString("status"),
                        rs.getLong("assigned_driver_id"), rs.getBigDecimal("final_fare"),
                        rs.getString("currency_code"),
                        instant(rs.getTimestamp("trip_completed_at")),
                        instant(rs.getTimestamp("driver_released_at"))),
                bookingPublicId, driverUserPublicId).stream().findFirst();
    }

    public Optional<SettlementDriver> lockDriver(long driverId) {
        return jdbc.query("""
                SELECT id, approval_status, operating_status FROM drivers WHERE id = ? FOR UPDATE
                """, (rs, row) -> new SettlementDriver(rs.getLong("id"),
                        rs.getString("approval_status"), rs.getString("operating_status")),
                driverId).stream().findFirst();
    }

    public Optional<SettlementPayment> lockPayment(long bookingId) {
        return jdbc.query("""
                SELECT id, public_id, status, method, amount, currency_code, paid_at
                FROM cash_payments WHERE booking_id = ? FOR UPDATE
                """, (rs, row) -> new SettlementPayment(rs.getLong("id"),
                        rs.getObject("public_id", UUID.class), rs.getString("status"),
                        rs.getString("method"), rs.getBigDecimal("amount"),
                        rs.getString("currency_code"), instant(rs.getTimestamp("paid_at"))),
                bookingId).stream().findFirst();
    }

    public boolean hasAccrual(long bookingId) {
        return Boolean.TRUE.equals(jdbc.queryForObject("""
                SELECT EXISTS (SELECT 1 FROM driver_commission_ledger
                               WHERE booking_id = ? AND event_type = 'COMMISSION_ACCRUED')
                """, Boolean.class, bookingId));
    }

    public void accrue(long bookingId, long driverId, String currency, BigDecimal fare,
                       BigDecimal rate, BigDecimal commission, String policyVersion, Instant at) {
        jdbc.update("""
                INSERT INTO driver_commission_ledger
                    (public_id, booking_id, driver_id, event_type, currency_code,
                     gross_cash_fare, commission_rate, commission_amount,
                     commission_policy_version, occurred_at)
                VALUES (?, ?, ?, 'COMMISSION_ACCRUED', ?, ?, ?, ?, ?, ?)
                """, UUID.randomUUID(), bookingId, driverId, currency, fare, rate,
                commission, policyVersion, Timestamp.from(at));
    }

    public int markPaid(long paymentId, long driverId, Instant at) {
        return jdbc.update("""
                UPDATE cash_payments SET status = 'PAID', collected_by_driver_id = ?, paid_at = ?,
                    updated_at = ?, version = version + 1
                WHERE id = ? AND status = 'PENDING'
                """, driverId, Timestamp.from(at), Timestamp.from(at), paymentId);
    }

    public int releaseBooking(long bookingId, long driverId, Instant at) {
        return jdbc.update("""
                UPDATE bookings SET driver_released_at = ?, updated_at = ?, version = version + 1
                WHERE id = ? AND assigned_driver_id = ? AND status = 'COMPLETED'
                    AND driver_released_at IS NULL
                """, Timestamp.from(at), Timestamp.from(at), bookingId, driverId);
    }

    public int returnDriverOnline(long driverId, Instant at) {
        return jdbc.update("""
                UPDATE drivers SET operating_status = 'ONLINE', updated_at = ?, version = version + 1
                WHERE id = ? AND operating_status = 'BUSY' AND approval_status = 'APPROVED'
                """, Timestamp.from(at), driverId);
    }

    public Optional<CashReceiptResponse> receipt(long bookingId) {
        return jdbc.query("""
                SELECT p.public_id AS payment_public_id, b.public_id AS booking_public_id,
                       p.status, p.method, p.amount, p.currency_code, l.commission_rate,
                       l.commission_amount, l.commission_policy_version, p.paid_at,
                       b.driver_released_at
                FROM cash_payments p JOIN bookings b ON b.id = p.booking_id
                JOIN driver_commission_ledger l ON l.booking_id = b.id
                    AND l.event_type = 'COMMISSION_ACCRUED'
                WHERE b.id = ? AND p.status = 'PAID' AND b.driver_released_at IS NOT NULL
                """, (rs, row) -> new CashReceiptResponse(
                        rs.getObject("payment_public_id", UUID.class),
                        rs.getObject("booking_public_id", UUID.class),
                        rs.getString("status"), rs.getString("method"),
                        rs.getBigDecimal("amount"), rs.getString("currency_code"),
                        rs.getBigDecimal("commission_rate"), rs.getBigDecimal("commission_amount"),
                        rs.getString("commission_policy_version"),
                        instant(rs.getTimestamp("paid_at")),
                        instant(rs.getTimestamp("driver_released_at"))), bookingId).stream().findFirst();
    }

    public Optional<CashPaymentResponse> visiblePayment(UUID bookingPublicId, UUID userPublicId, String role) {
        return jdbc.query("""
                SELECT p.public_id AS payment_public_id, b.public_id AS booking_public_id,
                       p.method, p.status, p.amount, p.currency_code, p.paid_at
                FROM cash_payments p JOIN bookings b ON b.id = p.booking_id
                JOIN users customer ON customer.id = b.customer_id
                LEFT JOIN drivers d ON d.id = b.assigned_driver_id
                LEFT JOIN users driver_user ON driver_user.id = d.user_id
                WHERE b.public_id = ? AND
                    ((? = 'CUSTOMER' AND customer.public_id = ?)
                     OR (? = 'DRIVER' AND driver_user.public_id = ?))
                """, (rs, row) -> new CashPaymentResponse(
                        rs.getObject("payment_public_id", UUID.class),
                        rs.getObject("booking_public_id", UUID.class),
                        rs.getString("method"), rs.getString("status"),
                        rs.getBigDecimal("amount"), rs.getString("currency_code"),
                        instant(rs.getTimestamp("paid_at"))), bookingPublicId,
                role, userPublicId, role, userPublicId).stream().findFirst();
    }

    public Optional<CommissionSummaryResponse> driverSummary(UUID driverUserPublicId) {
        return jdbc.query("""
                SELECT COALESCE(SUM(l.commission_amount), 0) AS due
                FROM drivers d JOIN users u ON u.id = d.user_id
                LEFT JOIN driver_commission_ledger l ON l.driver_id = d.id
                    AND l.event_type = 'COMMISSION_ACCRUED'
                WHERE u.public_id = ? GROUP BY d.id
                """, (rs, row) -> {
                    BigDecimal due = rs.getBigDecimal("due");
                    return new CommissionSummaryResponse(due, due, "VND");
                }, driverUserPublicId).stream().findFirst();
    }

    private static Instant instant(Timestamp timestamp) {
        return timestamp == null ? null : timestamp.toInstant();
    }

    public record SettlementBooking(long id, UUID publicId, String status, long driverId,
                                    BigDecimal fare, String currency, Instant completedAt,
                                    Instant releasedAt) {}
    public record SettlementDriver(long id, String approvalStatus, String operatingStatus) {}
    public record SettlementPayment(long id, UUID publicId, String status, String method,
                                    BigDecimal amount, String currency, Instant paidAt) {}
}
