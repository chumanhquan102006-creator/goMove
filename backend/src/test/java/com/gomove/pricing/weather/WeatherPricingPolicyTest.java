package com.gomove.pricing.weather;

import com.gomove.pricing.domain.GeoCoordinate;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class WeatherPricingPolicyTest {
    private static final Instant NOW = Instant.parse("2026-11-12T04:00:00Z");
    private static final GeoCoordinate PICKUP = new GeoCoordinate(new BigDecimal("21.03"), new BigDecimal("105.85"));

    @Test
    void classifiesRainAtInclusiveThresholdsAndUsesConfiguredMultipliers() {
        assertDecision("0", "NO_RAIN", "1.0000");
        assertDecision("0.199", "NO_RAIN", "1.0000");
        assertDecision("0.2", "RAIN", "1.1000");
        assertDecision("1.999", "RAIN", "1.1000");
        assertDecision("2.0", "HEAVY_RAIN", "1.1500");
    }

    @Test
    void invalidUnavailableStaleFutureAndUnsupportedObservationsFallBackWithoutClaimingNoRain() {
        assertThat(evaluate(new WeatherProvider.Observation(WeatherProvider.Status.AVAILABLE, NOW,
                new BigDecimal("-0.1"), 900, "mm")).reason()).isEqualTo("INVALID_DATA");
        assertThat(evaluate(WeatherProvider.Observation.unavailable()).reason()).isEqualTo("PROVIDER_UNAVAILABLE");
        assertThat(evaluate(WeatherProvider.Observation.available(NOW.minusSeconds(1801), BigDecimal.ZERO,
                900, "mm")).reason()).isEqualTo("STALE_DATA");
        assertThat(evaluate(WeatherProvider.Observation.available(NOW.plusSeconds(1), BigDecimal.ZERO,
                900, "mm")).reason()).isEqualTo("INVALID_DATA");
        assertThat(evaluate(WeatherProvider.Observation.available(NOW, BigDecimal.ZERO,
                3600, "mm")).reason()).isEqualTo("INVALID_DATA");
        assertThat(evaluate(WeatherProvider.Observation.available(NOW, BigDecimal.ZERO,
                900, "inch")).reason()).isEqualTo("INVALID_DATA");
    }

    @Test
    void disabledPolicyDoesNotCallProviderAndReturnsExplicitDisabledReason() {
        WeatherPricingProperties properties = properties(false);
        AtomicInteger calls = new AtomicInteger();
        WeatherPricingPolicy policy = new WeatherPricingPolicy(properties, coordinate -> {
            calls.incrementAndGet();
            return WeatherProvider.Observation.available(NOW, new BigDecimal("4.0"), 900, "mm");
        });

        WeatherPricingPolicy.Evaluation evaluation = policy.evaluate(NOW, PICKUP);

        assertThat(calls).hasValue(0);
        assertThat(evaluation.reason()).isEqualTo("FEATURE_DISABLED");
        assertThat(evaluation.multiplier()).isEqualByComparingTo("1.0000");
        assertThat(evaluation.observedAt()).isNull();
    }

    @Test
    void rejectsInvalidThresholdAndMultiplierConfiguration() {
        WeatherPricingProperties thresholds = properties(true);
        thresholds.setHeavyRainFromMm(new BigDecimal("0.1"));
        assertThatThrownBy(() -> new WeatherPricingPolicy(thresholds, coordinate -> WeatherProvider.Observation.invalid()))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("thresholds");

        WeatherPricingProperties multiplier = properties(true);
        multiplier.setRainMultiplier(new BigDecimal("0.80"));
        assertThatThrownBy(() -> new WeatherPricingPolicy(multiplier, coordinate -> WeatherProvider.Observation.invalid()))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("NUMERIC(8,4)");
    }

    private void assertDecision(String rain, String reason, String multiplier) {
        WeatherPricingPolicy.Evaluation result = evaluate(WeatherProvider.Observation.available(
                NOW.minusSeconds(300), new BigDecimal(rain), 900, "mm"));
        assertThat(result.reason()).isEqualTo(reason);
        assertThat(result.multiplier()).isEqualByComparingTo(multiplier);
        assertThat(result.evaluatedAt()).isEqualTo(NOW);
        assertThat(result.observedAt()).isEqualTo(NOW.minusSeconds(300));
    }

    private WeatherPricingPolicy.Evaluation evaluate(WeatherProvider.Observation observation) {
        return new WeatherPricingPolicy(properties(true), coordinate -> observation).evaluate(NOW, PICKUP);
    }

    static WeatherPricingProperties properties(boolean enabled) {
        WeatherPricingProperties properties = new WeatherPricingProperties();
        properties.setEnabled(enabled);
        return properties;
    }
}
