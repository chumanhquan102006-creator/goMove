package com.gomove.dispatch.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.common.exception.DomainException;
import com.gomove.dispatch.api.DriverOfferResponse;
import com.gomove.dispatch.api.OfferDecisionResponse;
import com.gomove.dispatch.infrastructure.DispatchStore;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.sql.SQLException;
import java.time.Clock;
import java.util.List;
import java.util.UUID;

@Service
public class DriverOfferService {
    private final DispatchStore store;
    private final OfferTransactionService transactions;
    private final Clock clock;

    public DriverOfferService(DispatchStore store, OfferTransactionService transactions, Clock clock) {
        this.store = store;
        this.transactions = transactions;
        this.clock = clock;
    }

    @Transactional(readOnly = true)
    public List<DriverOfferResponse> active(UUID driverUserPublicId, UserRole role) {
        requireDriver(role);
        return store.activeOffers(driverUserPublicId, clock.instant()).stream()
                .filter(offer -> clock.instant().isBefore(offer.expiresAt()))
                .map(DriverOfferResponse::from).toList();
    }

    public OfferDecisionResponse accept(UUID driverUserPublicId, UserRole role, UUID offerPublicId) {
        requireDriver(role);
        try {
            return transactions.accept(driverUserPublicId, offerPublicId);
        } catch (RuntimeException ex) {
            throw translateAfterRollback(ex);
        }
    }

    public OfferDecisionResponse reject(UUID driverUserPublicId, UserRole role, UUID offerPublicId) {
        requireDriver(role);
        try {
            return transactions.reject(driverUserPublicId, offerPublicId);
        } catch (RuntimeException ex) {
            throw translateAfterRollback(ex);
        }
    }

    private RuntimeException translateAfterRollback(RuntimeException ex) {
        for (Throwable cause = ex; cause != null; cause = cause.getCause()) {
            if (cause instanceof SQLException sql) {
                if ("55P03".equals(sql.getSQLState()) || "40P01".equals(sql.getSQLState())) {
                    return new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "OFFER_BUSY",
                            "Offer is busy; retry after the competing transaction finishes");
                }
                if ("23505".equals(sql.getSQLState())) {
                    return new DomainException(HttpStatus.CONFLICT, "OFFER_CONFLICT",
                            "Offer or driver was assigned concurrently");
                }
            }
        }
        return ex;
    }

    private void requireDriver(UserRole role) {
        if (role != UserRole.DRIVER) {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Driver role is required");
        }
    }
}
