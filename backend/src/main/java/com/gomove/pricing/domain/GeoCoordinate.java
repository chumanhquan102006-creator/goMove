package com.gomove.pricing.domain;

import java.math.BigDecimal;

public record GeoCoordinate(BigDecimal latitude, BigDecimal longitude) {
    public GeoCoordinate {
        if (latitude == null || longitude == null
                || latitude.compareTo(BigDecimal.valueOf(-90)) < 0
                || latitude.compareTo(BigDecimal.valueOf(90)) > 0
                || longitude.compareTo(BigDecimal.valueOf(-180)) < 0
                || longitude.compareTo(BigDecimal.valueOf(180)) > 0) {
            throw new IllegalArgumentException("Coordinates are outside valid bounds");
        }
    }
}
