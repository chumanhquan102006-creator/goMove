package com.gomove.booking.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.booking.domain.BookingStatus;
import com.gomove.booking.infrastructure.BookingCancellationStore;
import com.gomove.common.exception.DomainException;
import com.gomove.trip.api.TripTransitionResponse;
import com.gomove.trip.realtime.TripStatusEvent;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Clock;
import java.time.Instant;
import java.util.UUID;

@Service
public class BookingCancellationTransactionService {
    private final BookingCancellationStore store;
    private final ApplicationEventPublisher events;
    private final Clock clock;

    public BookingCancellationTransactionService(BookingCancellationStore store,
                                                 ApplicationEventPublisher events, Clock clock) {
        this.store = store;
        this.events = events;
        this.clock = clock;
    }

    @Transactional
    public TripTransitionResponse cancel(UUID bookingPublicId, UUID userPublicId, UserRole role) {
        // Shared order with offer acceptance and trip transitions: Booking -> Driver -> Offer.
        store.boundLockWait();
        var booking = (role == UserRole.CUSTOMER
                ? store.lockCustomerBooking(bookingPublicId, userPublicId)
                : store.lockDriverBooking(bookingPublicId, userPublicId))
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND,
                        "BOOKING_NOT_FOUND", "Booking not found"));
        if (booking.status() == BookingStatus.CANCELLED) {
            // Exact durable outcome for a lost HTTP response; never release the Driver twice.
            return new TripTransitionResponse(bookingPublicId, BookingStatus.CANCELLED, booking.cancelledAt());
        }
        if (booking.status() != BookingStatus.REQUESTED
                && booking.status() != BookingStatus.SEARCHING_DRIVER
                && booking.status() != BookingStatus.DRIVER_ACCEPTED
                && booking.status() != BookingStatus.DRIVER_ARRIVED) {
            throw new DomainException(HttpStatus.CONFLICT, "CANCELLATION_NOT_ALLOWED",
                    "Booking can no longer be cancelled before pickup");
        }
        if (role == UserRole.DRIVER && booking.driverId() == null) {
            throw new DomainException(HttpStatus.NOT_FOUND, "BOOKING_NOT_FOUND", "Booking not found");
        }
        if (booking.driverId() != null && !store.lockAssignedDriver(booking.driverId())) {
            throw new DomainException(HttpStatus.CONFLICT, "DRIVER_UNAVAILABLE", "Assigned driver is unavailable");
        }
        Instant at = store.cancel(booking.id(), role.name(), clock.instant());
        if (at == null) {
            throw new DomainException(HttpStatus.CONFLICT, "CANCELLATION_CONFLICT", "Booking changed concurrently");
        }
        store.cancelPendingOffer(booking.id(), at);
        if (booking.driverId() != null && store.releaseDriver(booking.driverId(), at) != 1) {
            throw new DomainException(HttpStatus.CONFLICT, "DRIVER_RELEASE_CONFLICT",
                    "Assigned driver could not be released");
        }
        events.publishEvent(new TripStatusEvent(bookingPublicId, BookingStatus.CANCELLED, at));
        return new TripTransitionResponse(bookingPublicId, BookingStatus.CANCELLED, at);
    }
}
