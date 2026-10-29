package com.gomove.trip.api;

import com.gomove.booking.domain.BookingStatus;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

/** Road estimates are transient guidance, not a change to the accepted Quote or fare. */
public record TripEtaResponse(UUID bookingPublicId, BookingStatus status, Phase phase,
                              Availability availability, Reason reason,
                              BigDecimal distanceMeters, BigDecimal durationSeconds,
                              Instant calculatedAt, Instant locationUpdatedAt, Instant expiresAt,
                              Instant servedAt) {
    public TripEtaResponse withServedAt(Instant now) {
        return new TripEtaResponse(bookingPublicId, status, phase, availability, reason,
                distanceMeters, durationSeconds, calculatedAt, locationUpdatedAt, expiresAt, now);
    }
    public enum Phase { PICKUP, DESTINATION, NONE }
    public enum Availability { AVAILABLE, UNAVAILABLE }
    public enum Reason {
        NOT_APPLICABLE, GPS_UNAVAILABLE, GPS_STALE, GPS_INACCURATE, ROUTING_UNAVAILABLE
    }
}
