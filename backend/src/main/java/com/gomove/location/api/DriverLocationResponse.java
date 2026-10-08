package com.gomove.location.api;

import com.gomove.location.domain.DriverLocation;

import java.time.Instant;

public record DriverLocationResponse(
        double latitude,
        double longitude,
        Double accuracy,
        Double bearing,
        Instant updatedAt
) {
    public static DriverLocationResponse from(DriverLocation location) {
        return new DriverLocationResponse(
                location.getCurrentLocation().getY(),
                location.getCurrentLocation().getX(),
                location.getAccuracy(),
                location.getBearing(),
                location.getUpdatedAt()
        );
    }
}
