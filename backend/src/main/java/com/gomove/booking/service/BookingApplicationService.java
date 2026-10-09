package com.gomove.booking.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.booking.api.BookingResponse;
import com.gomove.booking.domain.BookingRepository;
import com.gomove.common.exception.DomainException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.sql.SQLException;
import java.util.UUID;

@Service
public class BookingApplicationService {
    private final BookingTransactionService transactions;
    private final BookingRequestHash hashes;
    private final BookingRepository bookings;

    public BookingApplicationService(BookingTransactionService transactions, BookingRequestHash hashes,
                                     BookingRepository bookings) {
        this.transactions = transactions;
        this.hashes = hashes;
        this.bookings = bookings;
    }

    public BookingResult create(UUID customerPublicId, UserRole role, UUID quotePublicId, String rawKey) {
        requireCustomer(role);
        String key = BookingIdempotencyKey.requireValid(rawKey);
        String hash = hashes.calculate(customerPublicId, quotePublicId);
        try {
            return transactions.create(customerPublicId, quotePublicId, key, hash);
        } catch (RuntimeException ex) {
            // A PostgreSQL lock timeout aborts its transaction. Translate only after the proxy has rolled it back.
            if (hasSqlState(ex, "55P03")) {
                throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "BOOKING_BUSY",
                        "Booking is busy; retry with the same Idempotency-Key");
            }
            throw ex;
        }
    }

    @Transactional(readOnly = true)
    public BookingResponse getOwned(UUID bookingPublicId, UUID customerPublicId, UserRole role) {
        requireCustomer(role);
        return BookingResponse.from(bookings.findOwned(bookingPublicId, customerPublicId)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND,
                        "BOOKING_NOT_FOUND", "Booking not found")));
    }

    private void requireCustomer(UserRole role) {
        if (role != UserRole.CUSTOMER) {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Customer role is required");
        }
    }

    private boolean hasSqlState(Throwable ex, String state) {
        for (Throwable current = ex; current != null; current = current.getCause()) {
            if (current instanceof SQLException sql && state.equals(sql.getSQLState())) return true;
        }
        return false;
    }
}
