package com.gomove.trip.api;

import com.gomove.booking.domain.BookingStatus;
import com.gomove.trip.infrastructure.TripStore;
import java.time.Instant;
import java.util.UUID;

public record TrackingResponse(UUID bookingPublicId, BookingStatus status, UUID driverPublicId,
                               Instant driverAcceptedAt, Instant driverArrivedAt,
                               Instant passengerOnboardAt, Instant tripStartedAt, Instant tripCompletedAt,
                               Double latitude, Double longitude, Double accuracy, Double bearing,
                               Instant locationUpdatedAt) {
    public static TrackingResponse from(TripStore.TrackingState row) {
        return new TrackingResponse(row.bookingPublicId(), row.status(), row.driverPublicId(),
                row.driverAcceptedAt(), row.driverArrivedAt(), row.passengerOnboardAt(),
                row.tripStartedAt(), row.tripCompletedAt(), row.latitude(), row.longitude(),
                row.accuracy(), row.bearing(), row.locationUpdatedAt());
    }
}
