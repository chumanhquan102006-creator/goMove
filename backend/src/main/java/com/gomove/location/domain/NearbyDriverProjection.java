package com.gomove.location.domain;

import java.time.Instant;
import java.util.UUID;

public interface NearbyDriverProjection {
    UUID getDriverPublicId();

    UUID getVehiclePublicId();

    Double getLatitude();

    Double getLongitude();

    Double getDistanceMeters();

    Instant getLocationUpdatedAt();
}
