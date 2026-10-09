package com.gomove.booking.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.auth.domain.UserRole;
import com.gomove.booking.api.BookingResponse;
import com.gomove.booking.domain.Booking;
import com.gomove.booking.domain.BookingRepository;
import com.gomove.common.api.ApiResponse;
import com.gomove.common.exception.DomainException;
import com.gomove.pricing.domain.Quote;
import com.gomove.pricing.domain.QuoteRepository;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Clock;
import java.time.Instant;
import java.util.UUID;

@Service
public class BookingTransactionService {
    private final UserRepository users;
    private final QuoteRepository quotes;
    private final BookingRepository bookings;
    private final BookingIdempotencyStore idempotency;
    private final ObjectMapper mapper;
    private final Clock clock;

    public BookingTransactionService(UserRepository users, QuoteRepository quotes, BookingRepository bookings,
                                     BookingIdempotencyStore idempotency, ObjectMapper mapper, Clock clock) {
        this.users = users;
        this.quotes = quotes;
        this.bookings = bookings;
        this.idempotency = idempotency;
        this.mapper = mapper;
        this.clock = clock;
    }

    @Transactional
    public BookingResult create(UUID customerPublicId, UUID quotePublicId, String key, String requestHash) {
        User customer = users.findByPublicId(customerPublicId)
                .orElseThrow(() -> new DomainException(HttpStatus.UNAUTHORIZED, "UNAUTHORIZED", "Authenticated user was not found"));
        if (customer.getRole() != UserRole.CUSTOMER) {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Customer role is required");
        }

        // Lock order: unique customer/key claim, then Quote row. All work uses this one transaction.
        idempotency.boundLockWait();
        Long claimId = idempotency.claim(customer.getId(), key, requestHash);
        if (claimId == null) return idempotency.existing(customer.getId(), key).replay(requestHash);

        Quote quote = quotes.lockOwnedForBooking(quotePublicId, customerPublicId)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND, "QUOTE_NOT_FOUND", "Quote not found"));
        Instant consumedAt = clock.instant(); // Read after FOR UPDATE; never use transaction-start time for expiry.
        quote.consume(consumedAt);

        Booking booking = bookings.saveAndFlush(new Booking(customer, quote));
        quotes.flush(); // Persist status, consumedAt and optimistic version before storing the replay outcome.
        ApiResponse<BookingResponse> response = new ApiResponse<>(true, "BOOKING_CREATED", "Booking created",
                BookingResponse.from(booking), clock.instant());
        String responseJson;
        try {
            responseJson = mapper.writeValueAsString(response);
        } catch (JsonProcessingException ex) {
            throw new IllegalStateException("Cannot serialize Booking response", ex);
        }
        return new BookingResult(201, idempotency.finish(claimId, booking.getId(), responseJson));
    }
}
