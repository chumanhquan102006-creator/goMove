package com.gomove.trip.realtime;

import com.gomove.booking.domain.BookingStatus;
import java.time.Instant;
import java.util.UUID;

public record TripStatusEvent(String type, UUID bookingPublicId, BookingStatus status, Instant occurredAt) {
    public TripStatusEvent(UUID bookingPublicId, BookingStatus status, Instant occurredAt) {
        this("TRIP_STATUS_CHANGED", bookingPublicId, status, occurredAt);
    }
}
