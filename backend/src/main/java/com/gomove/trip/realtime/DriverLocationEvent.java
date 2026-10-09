package com.gomove.trip.realtime;

import java.time.Instant;
import java.util.UUID;

public record DriverLocationEvent(String type, UUID bookingPublicId, double latitude, double longitude,
                                  Double accuracy, Double bearing, Instant recordedAt) {
    public DriverLocationEvent(UUID bookingPublicId, double latitude, double longitude,
                               Double accuracy, Double bearing, Instant recordedAt) {
        this("DRIVER_LOCATION_UPDATED", bookingPublicId, latitude, longitude, accuracy, bearing, recordedAt);
    }
}
