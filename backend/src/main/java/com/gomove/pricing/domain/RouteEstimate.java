package com.gomove.pricing.domain;

import java.math.BigDecimal;
import java.math.RoundingMode;

public record RouteEstimate(BigDecimal distanceMeters, BigDecimal durationSeconds, String provider) {
    public RouteEstimate {
        if (distanceMeters == null || durationSeconds == null
                || distanceMeters.signum() <= 0 || durationSeconds.signum() <= 0
                || provider == null || provider.isBlank()) {
            throw new IllegalArgumentException("A valid road route requires positive distance and duration");
        }
        distanceMeters = distanceMeters.setScale(3, RoundingMode.HALF_UP);
        durationSeconds = durationSeconds.setScale(3, RoundingMode.HALF_UP);
        if (distanceMeters.signum() <= 0 || durationSeconds.signum() <= 0) {
            throw new IllegalArgumentException("Road route is too short to price");
        }
        if (distanceMeters.precision() - distanceMeters.scale() > 12
                || durationSeconds.precision() - durationSeconds.scale() > 12
                || provider.length() > 40) {
            throw new IllegalArgumentException("Road route exceeds supported storage precision");
        }
    }
}
