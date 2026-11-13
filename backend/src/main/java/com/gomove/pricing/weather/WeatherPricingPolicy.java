package com.gomove.pricing.weather;

import com.gomove.pricing.domain.GeoCoordinate;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Duration;
import java.time.Instant;

/** Converts one validated provider observation into an immutable weather pricing decision. */
@Component
public class WeatherPricingPolicy {
    private static final BigDecimal IDENTITY = BigDecimal.ONE.setScale(4);
    private final WeatherPricingProperties properties;
    private final WeatherProvider provider;

    public WeatherPricingPolicy(WeatherPricingProperties properties, WeatherProvider provider) {
        this.properties = properties;
        this.provider = provider;
        validate(properties);
    }

    public Evaluation evaluate(Instant evaluatedAt, GeoCoordinate pickup) {
        if (evaluatedAt == null || pickup == null) throw new IllegalArgumentException("Pricing time and pickup are required");
        if (!properties.isEnabled()) {
            return evaluation(evaluatedAt, null, null, "NOT_REQUESTED", null, IDENTITY,
                    false, "FEATURE_DISABLED");
        }

        WeatherProvider.Observation observation;
        try {
            observation = provider.currentRain(pickup);
        } catch (RuntimeException ex) {
            observation = WeatherProvider.Observation.unavailable();
        }
        if (observation == null) observation = WeatherProvider.Observation.invalid();
        if (observation.status() == WeatherProvider.Status.PROVIDER_UNAVAILABLE) {
            return evaluation(evaluatedAt, null, null, "PROVIDER_UNAVAILABLE", null, IDENTITY,
                    false, "PROVIDER_UNAVAILABLE");
        }
        if (observation.status() != WeatherProvider.Status.AVAILABLE
                || !valid(observation)) {
            return evaluation(evaluatedAt, observation.observedAt(), observation.rainMm(),
                    "INVALID_DATA", observation.intervalSeconds(), IDENTITY, false, "INVALID_DATA");
        }

        Duration age = Duration.between(observation.observedAt(), evaluatedAt);
        if (age.isNegative()) {
            return evaluation(evaluatedAt, observation.observedAt(), observation.rainMm(),
                    "INVALID_DATA", observation.intervalSeconds(), IDENTITY, false, "INVALID_DATA");
        }
        if (age.compareTo(properties.getMaximumAge()) > 0) {
            return evaluation(evaluatedAt, observation.observedAt(), observation.rainMm(),
                    "STALE_DATA", observation.intervalSeconds(), IDENTITY, false, "STALE_DATA");
        }

        BigDecimal rain = observation.rainMm();
        if (rain.compareTo(properties.getNoRainBelowMm()) < 0) {
            return evaluation(evaluatedAt, observation.observedAt(), rain, "AVAILABLE",
                    observation.intervalSeconds(), IDENTITY, false, "NO_RAIN");
        }
        if (rain.compareTo(properties.getHeavyRainFromMm()) < 0) {
            return evaluation(evaluatedAt, observation.observedAt(), rain, "AVAILABLE",
                    observation.intervalSeconds(), multiplier(properties.getRainMultiplier()), true, "RAIN");
        }
        return evaluation(evaluatedAt, observation.observedAt(), rain, "AVAILABLE",
                observation.intervalSeconds(), multiplier(properties.getHeavyRainMultiplier()), true, "HEAVY_RAIN");
    }

    public BigDecimal maximumCombinedMultiplier() {
        return properties.getMaximumCombinedMultiplier();
    }

    private Evaluation evaluation(Instant evaluatedAt, Instant observedAt, BigDecimal rainMm,
                                  String dataStatus, Integer intervalSeconds, BigDecimal multiplier,
                                  boolean applied, String reason) {
        return new Evaluation(properties.getPolicyVersion(), properties.getProvider(), evaluatedAt,
                observedAt, rainMm, intervalSeconds, dataStatus, "mm", multiplier, applied, reason,
                properties.getNoRainBelowMm(), properties.getHeavyRainFromMm(),
                properties.getRainMultiplier(), properties.getHeavyRainMultiplier(),
                properties.getMaximumAge().toSeconds());
    }

    private boolean valid(WeatherProvider.Observation observation) {
        return observation.observedAt() != null && observation.rainMm() != null
                && observation.rainMm().signum() >= 0
                && observation.intervalSeconds() != null
                && observation.intervalSeconds() == properties.getExpectedIntervalSeconds()
                && "mm".equals(observation.unit());
    }

    private BigDecimal multiplier(BigDecimal value) {
        return value.setScale(4, RoundingMode.UNNECESSARY);
    }

    private void validate(WeatherPricingProperties config) {
        if (config.getPolicyVersion() == null || config.getPolicyVersion().isBlank()
                || !"OPEN_METEO".equals(config.getProvider())) {
            throw new IllegalArgumentException("Weather policy version and provider are required");
        }
        if (config.getNoRainBelowMm() == null || config.getNoRainBelowMm().signum() < 0
                || config.getHeavyRainFromMm() == null
                || config.getHeavyRainFromMm().compareTo(config.getNoRainBelowMm()) <= 0) {
            throw new IllegalArgumentException("Weather rain thresholds must be non-negative and increasing");
        }
        requireMultiplier(config.getRainMultiplier(), "rainMultiplier");
        requireMultiplier(config.getHeavyRainMultiplier(), "heavyRainMultiplier");
        requireMultiplier(config.getMaximumCombinedMultiplier(), "maximumCombinedMultiplier");
        if (config.getHeavyRainMultiplier().compareTo(config.getRainMultiplier()) < 0) {
            throw new IllegalArgumentException("Heavy-rain multiplier cannot be lower than the rain multiplier");
        }
        if (config.getNoRainBelowMm().scale() > 3 || config.getNoRainBelowMm().precision() > 6
                || config.getHeavyRainFromMm().scale() > 3 || config.getHeavyRainFromMm().precision() > 6) {
            throw new IllegalArgumentException("Weather rain thresholds must use bounded millimetre precision");
        }
        if (config.getExpectedIntervalSeconds() <= 0 || config.getMaximumAge() == null
                || config.getMaximumAge().isNegative() || config.getMaximumAge().isZero()
                || config.getMaximumAge().toSeconds() <= 0) {
            throw new IllegalArgumentException("Weather interval and maximum age must be positive");
        }
    }

    private void requireMultiplier(BigDecimal value, String name) {
        if (value == null || value.compareTo(BigDecimal.ONE) < 0 || value.scale() > 4
                || value.precision() - value.scale() > 4) {
            throw new IllegalArgumentException(name + " must be at least 1.0000 and fit NUMERIC(8,4)");
        }
    }

    public record Evaluation(String policyVersion, String provider, Instant evaluatedAt, Instant observedAt,
                             BigDecimal rainMm, Integer intervalSeconds, String dataStatus, String unit,
                             BigDecimal multiplier, boolean applied, String reason,
                             BigDecimal noRainBelowMm, BigDecimal heavyRainFromMm,
                             BigDecimal configuredRainMultiplier, BigDecimal configuredHeavyRainMultiplier,
                             long maximumAgeSeconds) {
        public Evaluation {
            if (policyVersion == null || provider == null || evaluatedAt == null || dataStatus == null
                    || unit == null || multiplier == null || reason == null || noRainBelowMm == null
                    || heavyRainFromMm == null || configuredRainMultiplier == null
                    || configuredHeavyRainMultiplier == null || maximumAgeSeconds <= 0) {
                throw new IllegalArgumentException("Complete weather pricing evaluation is required");
            }
        }
    }
}
