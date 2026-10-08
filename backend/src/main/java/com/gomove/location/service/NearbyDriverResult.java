package com.gomove.location.service;

import java.time.Instant;
import java.util.UUID;

public record NearbyDriverResult(
        UUID driverPublicId,
        UUID vehiclePublicId,
        double latitude,
        double longitude,
        double distanceMeters,
        Instant locationUpdatedAt
) {
}
