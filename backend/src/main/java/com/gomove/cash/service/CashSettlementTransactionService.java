package com.gomove.cash.service;

import com.gomove.cash.api.CashReceiptResponse;
import com.gomove.cash.infrastructure.CashSettlementStore;
import com.gomove.cash.infrastructure.CashSettlementStore.SettlementBooking;
import com.gomove.cash.infrastructure.CashSettlementStore.SettlementDriver;
import com.gomove.cash.infrastructure.CashSettlementStore.SettlementPayment;
import com.gomove.common.exception.DomainException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Clock;
import java.time.Instant;
import java.util.UUID;

@Service
public class CashSettlementTransactionService {
    private final CashSettlementStore store;
    private final CommissionCalculator calculator;
    private final Clock clock;

    public CashSettlementTransactionService(CashSettlementStore store,
                                            CommissionCalculator calculator, Clock clock) {
        this.store = store;
        this.calculator = calculator;
        this.clock = clock;
    }

    @Transactional
    public CashReceiptResponse confirm(UUID bookingPublicId, UUID driverUserPublicId) {
        // Same leading lock order as V11 acceptance: Booking -> Driver; then lock Payment.
        // The Booking lock serializes concurrent confirmation and trip transitions.
        store.boundLockWait();
        SettlementBooking booking = store.lockAssignedBooking(bookingPublicId, driverUserPublicId)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND,
                        "BOOKING_NOT_FOUND", "Booking not found"));
        SettlementDriver driver = store.lockDriver(booking.driverId())
                .orElseThrow(() -> conflict("Assigned Driver record is missing"));
        SettlementPayment payment = store.lockPayment(booking.id())
                .orElseThrow(() -> conflict("CASH payment record is missing"));

        if ("PAID".equals(payment.status())) {
            // Replay reads only durable values; do not touch a Driver who may now be BUSY elsewhere.
            if (booking.releasedAt() == null || !"COMPLETED".equals(booking.status())) {
                throw conflict("Cash settlement is inconsistent");
            }
            return store.receipt(booking.id()).orElseThrow(() -> conflict("Cash receipt is incomplete"));
        }
        if (!"CASH".equals(payment.method()) || !"PENDING".equals(payment.status())
                || !"COMPLETED".equals(booking.status()) || booking.completedAt() == null
                || booking.releasedAt() != null || !"BUSY".equals(driver.operatingStatus())
                || !"APPROVED".equals(driver.approvalStatus())
                || payment.amount().compareTo(booking.fare()) != 0
                || !payment.currency().equals(booking.currency()) || !"VND".equals(booking.currency())
                || store.hasAccrual(booking.id())) {
            throw conflict("Cash confirmation is unavailable in the current state");
        }

        CommissionCalculator.Calculation calculation;
        try {
            calculation = calculator.calculate(booking.fare());
        } catch (IllegalArgumentException ex) {
            throw conflict("Accepted fare cannot be settled with the configured commission policy");
        }
        // Read server time after locks; clamp only to the persisted completion instant so
        // paid/released timestamps never precede completion if clocks differ slightly.
        Instant at = clock.instant();
        if (at.isBefore(booking.completedAt())) at = booking.completedAt();
        store.accrue(booking.id(), driver.id(), booking.currency(), booking.fare(),
                calculation.rate(), calculation.commissionDue(), calculation.policyVersion(), at);
        if (store.markPaid(payment.id(), driver.id(), at) != 1
                || store.releaseBooking(booking.id(), driver.id(), at) != 1
                || store.returnDriverOnline(driver.id(), at) != 1) {
            throw conflict("Cash settlement state changed; retry safely");
        }
        return store.receipt(booking.id()).orElseThrow(() -> conflict("Cash receipt is incomplete"));
    }

    private DomainException conflict(String message) {
        return new DomainException(HttpStatus.CONFLICT, "CASH_SETTLEMENT_CONFLICT", message);
    }
}
