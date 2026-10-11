package com.gomove.cash.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.cash.api.CashPaymentResponse;
import com.gomove.cash.api.CashReceiptResponse;
import com.gomove.cash.api.CommissionSummaryResponse;
import com.gomove.cash.infrastructure.CashSettlementStore;
import com.gomove.common.exception.DomainException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.sql.SQLException;
import java.util.UUID;

@Service
public class CashSettlementApplicationService {
    private final CashSettlementTransactionService transactions;
    private final CashSettlementStore store;

    public CashSettlementApplicationService(CashSettlementTransactionService transactions,
                                            CashSettlementStore store) {
        this.transactions = transactions;
        this.store = store;
    }

    public CashReceiptResponse confirm(UUID bookingPublicId, UUID driverUserPublicId, UserRole role) {
        requireDriver(role);
        try {
            return transactions.confirm(bookingPublicId, driverUserPublicId);
        } catch (RuntimeException ex) {
            // PostgreSQL aborts on lock timeout. Translate only after the transaction proxy rolls back.
            if (hasSqlState(ex, "55P03")) {
                throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "CASH_SETTLEMENT_BUSY",
                        "Cash settlement is busy; retry the same Booking");
            }
            throw ex;
        }
    }

    @Transactional(readOnly = true)
    public CashPaymentResponse payment(UUID bookingPublicId, UUID userPublicId, UserRole role) {
        if (role != UserRole.CUSTOMER && role != UserRole.DRIVER) {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Trip participant required");
        }
        return store.visiblePayment(bookingPublicId, userPublicId, role.name())
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND,
                        "BOOKING_NOT_FOUND", "Booking not found"));
    }

    @Transactional(readOnly = true)
    public CommissionSummaryResponse summary(UUID driverUserPublicId, UserRole role) {
        requireDriver(role);
        return store.driverSummary(driverUserPublicId)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND,
                        "DRIVER_NOT_FOUND", "Driver not found"));
    }

    private void requireDriver(UserRole role) {
        if (role != UserRole.DRIVER) {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Driver role is required");
        }
    }

    private boolean hasSqlState(Throwable ex, String state) {
        for (Throwable current = ex; current != null; current = current.getCause()) {
            if (current instanceof SQLException sql && state.equals(sql.getSQLState())) return true;
        }
        return false;
    }
}
