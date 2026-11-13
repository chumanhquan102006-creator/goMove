package com.gomove.pricing.weather;

import com.gomove.pricing.domain.GeoCoordinate;

import java.math.BigDecimal;
import java.time.Instant;

/** Outbound weather boundary used by server-side quote pricing. */
public interface WeatherProvider {
    Observation currentRain(GeoCoordinate pickup);

    enum Status { AVAILABLE, PROVIDER_UNAVAILABLE, INVALID_DATA }

    record Observation(Status status, Instant observedAt, BigDecimal rainMm,
                       Integer intervalSeconds, String unit) {
        public static Observation unavailable() {
            return new Observation(Status.PROVIDER_UNAVAILABLE, null, null, null, null);
        }

        public static Observation invalid() {
            return new Observation(Status.INVALID_DATA, null, null, null, null);
        }

        public static Observation available(Instant observedAt, BigDecimal rainMm,
                                            Integer intervalSeconds, String unit) {
            return new Observation(Status.AVAILABLE, observedAt, rainMm, intervalSeconds, unit);
        }
    }
}
