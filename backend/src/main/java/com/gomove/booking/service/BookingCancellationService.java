package com.gomove.booking.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.common.exception.DomainException;
import com.gomove.trip.api.TripTransitionResponse;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;

import java.sql.SQLException;
import java.util.UUID;

@Service
public class BookingCancellationService {
    private final BookingCancellationTransactionService transactions;

    public BookingCancellationService(BookingCancellationTransactionService transactions) {
        this.transactions = transactions;
    }

    public TripTransitionResponse cancel(UUID bookingPublicId, UUID userPublicId, UserRole role) {
        if (role != UserRole.CUSTOMER && role != UserRole.DRIVER) {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Trip participant role is required");
        }
        try {
            return transactions.cancel(bookingPublicId, userPublicId, role);
        } catch (RuntimeException ex) {
            for (Throwable cause = ex; cause != null; cause = cause.getCause()) {
                if (cause instanceof SQLException sql
                        && ("55P03".equals(sql.getSQLState()) || "40P01".equals(sql.getSQLState()))) {
                    throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "CANCELLATION_BUSY",
                            "Cancellation is busy; retry after reconciling Booking state");
                }
            }
            throw ex;
        }
    }
}
