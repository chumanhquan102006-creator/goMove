package com.gomove.pricing.demandsupply;

import org.junit.jupiter.api.Test;
import org.springframework.dao.DataAccessResourceFailureException;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class DemandSupplyPricingPolicyTest {
    private static final Instant NOW = Instant.parse("2030-01-01T01:00:00Z");

    @Test
    void disabledFeatureReturnsNeutralWithoutCallingTheMetricsProvider() {
        DemandSupplyPricingProperties config = properties(false);
        AtomicInteger calls = new AtomicInteger();
        DemandSupplyProvider provider = (pickup, vehicleType, evaluatedAt) -> {
            calls.incrementAndGet();
            return metrics(100, 0);
        };
        DemandSupplyPricingService service = new DemandSupplyPricingService(config, provider,
                new DemandSupplyPricingPolicy(config));

        assertThat(service.evaluate(NOW, pickup(), com.gomove.vehicle.domain.VehicleType.MOTORBIKE)).isNull();
        assertThat(calls).hasValue(0);
    }

    @Test
    void zeroDemandAndDemandBelowMinimumNeverRaiseTheFare() {
        DemandSupplyPricingPolicy policy = policy();

        var zero = policy.evaluate(NOW, metrics(0, 0));
        var belowMinimum = policy.evaluate(NOW, metrics(2, 0));

        assertThat(zero.requestedMultiplier()).isEqualByComparingTo("1.0000");
        assertThat(zero.reason()).isEqualTo("ZERO_DEMAND");
        assertThat(belowMinimum.requestedMultiplier()).isEqualByComparingTo("1.0000");
        assertThat(belowMinimum.reason()).isEqualTo("BELOW_MINIMUM_DEMAND");
    }

    @Test
    void belowTwoToOneRatioUsesIdentityMultiplier() {
        var evaluation = policy().evaluate(NOW, metrics(3, 2));
        assertThat(evaluation.requestedMultiplier()).isEqualByComparingTo("1.0000");
        assertThat(evaluation.reason()).isEqualTo("BELOW_LOW_RATIO");
    }

    @Test
    void exactTwoAndJustBelowFourUseModerateMultiplier() {
        DemandSupplyPricingPolicy policy = policy();

        var exactTwo = policy.evaluate(NOW, metrics(4, 2));
        var belowFour = policy.evaluate(NOW, metrics(7, 2));

        assertThat(exactTwo.requestedMultiplier()).isEqualByComparingTo("1.1000");
        assertThat(belowFour.requestedMultiplier()).isEqualByComparingTo("1.1000");
        assertThat(exactTwo.reason()).isEqualTo("MODERATE_DEMAND_SUPPLY_RATIO");
        assertThat(belowFour.reason()).isEqualTo("MODERATE_DEMAND_SUPPLY_RATIO");
    }

    @Test
    void exactFourToOneRatioUsesHighMultiplierWithinConfiguredMaximum() {
        var evaluation = policy().evaluate(NOW, metrics(8, 2));

        assertThat(evaluation.requestedMultiplier()).isEqualByComparingTo("1.2000");
        assertThat(evaluation.requestedMultiplier()).isLessThanOrEqualTo(evaluation.maximumMultiplier());
        assertThat(evaluation.reason()).isEqualTo("HIGH_DEMAND_SUPPLY_RATIO");
    }

    @Test
    void zeroAvailableDriversUseEffectiveSupplyFloorOfOne() {
        var evaluation = policy().evaluate(NOW, metrics(3, 0));

        assertThat(evaluation.availableDriverCount()).isZero();
        assertThat(evaluation.effectiveSupplyForRatio()).isEqualTo(1L);
        assertThat(evaluation.requestedMultiplier()).isEqualByComparingTo("1.1000");
    }

    @Test
    void databaseFailureAndUnreliableGpsFailOpenWithDistinctReasons() {
        DemandSupplyPricingPolicy policy = policy();
        var failed = policy.evaluate(NOW, DemandSupplyMetrics.unavailable());
        var unreliable = policy.evaluate(NOW, new DemandSupplyMetrics(
                DemandSupplyMetrics.Status.LOCATION_DATA_UNRELIABLE, 9L, 0L, 2L, 1L,
                "STALE_OR_FUTURE_GPS_NEAR_PICKUP"));

        assertThat(failed.requestedMultiplier()).isEqualByComparingTo("1.0000");
        assertThat(failed.reason()).isEqualTo("DATABASE_QUERY_FAILED");
        assertThat(failed.dataStatus()).isEqualTo("METRICS_UNAVAILABLE");
        assertThat(failed.demandCount()).isNull();
        assertThat(unreliable.requestedMultiplier()).isEqualByComparingTo("1.0000");
        assertThat(unreliable.reason()).isEqualTo("STALE_OR_FUTURE_GPS_NEAR_PICKUP");
        assertThat(unreliable.dataStatus()).isEqualTo("LOCATION_DATA_UNRELIABLE");
    }

    @Test
    void providerDataAccessFailureIsConvertedToNeutralEvaluation() {
        DemandSupplyPricingProperties config = properties(true);
        DemandSupplyPricingPolicy policy = new DemandSupplyPricingPolicy(config);
        DemandSupplyProvider provider = (pickup, vehicleType, evaluatedAt) -> {
            throw new DataAccessResourceFailureException("db unavailable");
        };
        DemandSupplyPricingService service = new DemandSupplyPricingService(config, provider, policy);

        var evaluation = service.evaluate(NOW, pickup(), com.gomove.vehicle.domain.VehicleType.MOTORBIKE);

        assertThat(evaluation.requestedMultiplier()).isEqualByComparingTo("1.0000");
        assertThat(evaluation.dataStatus()).isEqualTo("METRICS_UNAVAILABLE");
        assertThat(evaluation.reason()).isEqualTo("DATABASE_QUERY_FAILED");
    }

    @Test
    void negativeCountsAndInvalidConfigurationAreRejected() {
        assertThatThrownBy(() -> DemandSupplyMetrics.available(-1, 0, 0, 0))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> DemandSupplyMetrics.available(1, -1, 0, 0))
                .isInstanceOf(IllegalArgumentException.class);

        DemandSupplyPricingProperties badRadius = properties(true);
        badRadius.setRadiusMeters(0);
        assertThatThrownBy(() -> new DemandSupplyPricingPolicy(badRadius))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("radius");

        DemandSupplyPricingProperties badMultiplier = properties(true);
        badMultiplier.setHighMultiplier(new BigDecimal("0.80"));
        assertThatThrownBy(() -> new DemandSupplyPricingPolicy(badMultiplier))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("highMultiplier");

        DemandSupplyPricingProperties excessivePrecision = properties(true);
        excessivePrecision.setModerateMultiplier(new BigDecimal("1.10001"));
        assertThatThrownBy(() -> new DemandSupplyPricingPolicy(excessivePrecision))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("moderateMultiplier");

        DemandSupplyPricingProperties multiplierOverCap = properties(true);
        multiplierOverCap.setMaximumMultiplier(new BigDecimal("1.1500"));
        assertThatThrownBy(() -> new DemandSupplyPricingPolicy(multiplierOverCap))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("ordered");

        DemandSupplyPricingProperties badLookback = properties(true);
        badLookback.setLookback(java.time.Duration.ofHours(2));
        assertThatThrownBy(() -> new DemandSupplyPricingPolicy(badLookback))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("lookback");

        DemandSupplyPricingProperties badThresholds = properties(true);
        badThresholds.setHighRatioThreshold(new BigDecimal("2.0"));
        assertThatThrownBy(() -> new DemandSupplyPricingPolicy(badThresholds))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("High demand ratio");
    }

    private DemandSupplyPricingPolicy policy() {
        return new DemandSupplyPricingPolicy(properties(true));
    }

    private DemandSupplyMetrics metrics(long demand, long supply) {
        return DemandSupplyMetrics.available(demand, supply, supply, supply);
    }

    private DemandSupplyPricingProperties properties(boolean enabled) {
        DemandSupplyPricingProperties config = new DemandSupplyPricingProperties();
        config.setEnabled(enabled);
        return config;
    }

    private com.gomove.pricing.domain.GeoCoordinate pickup() {
        return new com.gomove.pricing.domain.GeoCoordinate(new BigDecimal("21.0287"), new BigDecimal("105.8524"));
    }
}
