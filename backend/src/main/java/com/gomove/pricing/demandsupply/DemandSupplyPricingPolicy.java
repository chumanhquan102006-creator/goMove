package com.gomove.pricing.demandsupply;

import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.time.Instant;

/** Pure, deterministic demand/supply tier selection. */
@Component
public class DemandSupplyPricingPolicy {
    private static final BigDecimal IDENTITY = new BigDecimal("1.0000");
    private final DemandSupplyPricingProperties properties;

    public DemandSupplyPricingPolicy(DemandSupplyPricingProperties properties) {
        validate(properties);
        this.properties = properties;
    }

    public Evaluation evaluate(Instant evaluatedAt, DemandSupplyMetrics metrics) {
        if (evaluatedAt == null || metrics == null) {
            throw new IllegalArgumentException("Evaluation time and demand/supply metrics are required");
        }
        if (!properties.isEnabled()) {
            return result(evaluatedAt, "NOT_QUERIED", "FEATURE_DISABLED", null, null,
                    null, null, IDENTITY, null);
        }
        if (metrics.status() == DemandSupplyMetrics.Status.METRICS_UNAVAILABLE) {
            return result(evaluatedAt, metrics.status().name(), metrics.reason(), metrics,
                    IDENTITY, null);
        }
        if (metrics.status() == DemandSupplyMetrics.Status.LOCATION_DATA_UNRELIABLE) {
            return result(evaluatedAt, metrics.status().name(), metrics.reason(), metrics,
                    IDENTITY, null);
        }

        long demand = metrics.demandCount();
        long supply = metrics.availableDriverCount();
        long effectiveSupply = Math.max(supply, 1L);
        if (demand == 0) {
            return result(evaluatedAt, metrics.status().name(), "ZERO_DEMAND", metrics,
                    IDENTITY, effectiveSupply);
        }
        if (demand < properties.getMinimumDemand()) {
            return result(evaluatedAt, metrics.status().name(), "BELOW_MINIMUM_DEMAND", metrics,
                    IDENTITY, effectiveSupply);
        }

        BigDecimal ratioDemand = BigDecimal.valueOf(demand);
        BigDecimal ratioSupply = BigDecimal.valueOf(effectiveSupply);
        if (ratioDemand.compareTo(properties.getLowRatioThreshold().multiply(ratioSupply)) < 0) {
            return result(evaluatedAt, metrics.status().name(), "BELOW_LOW_RATIO", metrics,
                    IDENTITY, effectiveSupply);
        }
        if (ratioDemand.compareTo(properties.getHighRatioThreshold().multiply(ratioSupply)) < 0) {
            return result(evaluatedAt, metrics.status().name(), "MODERATE_DEMAND_SUPPLY_RATIO", metrics,
                    properties.getModerateMultiplier(), effectiveSupply);
        }
        return result(evaluatedAt, metrics.status().name(), "HIGH_DEMAND_SUPPLY_RATIO", metrics,
                properties.getHighMultiplier(), effectiveSupply);
    }

    private Evaluation result(Instant evaluatedAt, String dataStatus, String reason,
                              DemandSupplyMetrics metrics, BigDecimal multiplier, Long effectiveSupply) {
        return result(evaluatedAt, dataStatus, reason,
                metrics == null ? null : metrics.demandCount(),
                metrics == null ? null : metrics.availableDriverCount(),
                metrics == null ? null : metrics.eligibleDriverCount(),
                metrics == null ? null : metrics.freshEligibleDriverCount(),
                multiplier, effectiveSupply);
    }

    private Evaluation result(Instant evaluatedAt, String dataStatus, String reason,
                              Long demandCount, Long availableDriverCount,
                              Long eligibleDriverCount, Long freshEligibleDriverCount,
                              BigDecimal multiplier, Long effectiveSupply) {
        return new Evaluation(properties.getPolicyVersion(), evaluatedAt, dataStatus, reason,
                demandCount, availableDriverCount, eligibleDriverCount, freshEligibleDriverCount,
                properties.getRadiusMeters(), properties.getLookback().toSeconds(),
                properties.getDriverLocationFreshnessSeconds(), properties.getMinimumDemand(),
                properties.getLowRatioThreshold(), properties.getHighRatioThreshold(),
                properties.getModerateMultiplier(), properties.getHighMultiplier(),
                properties.getMaximumMultiplier(), multiplier, effectiveSupply);
    }

    private void validate(DemandSupplyPricingProperties config) {
        if (config == null || config.getPolicyVersion() == null || config.getPolicyVersion().isBlank()) {
            throw new IllegalArgumentException("Demand/supply policy version is required");
        }
        if (config.getRadiusMeters() < 1 || config.getRadiusMeters() > 50_000) {
            throw new IllegalArgumentException("Demand/supply radius must be between 1 and 50000 meters");
        }
        if (config.getLookback() == null || config.getLookback().isZero() || config.getLookback().isNegative()
                || config.getLookback().compareTo(DurationBounds.MAX_LOOKBACK) > 0
                || config.getLookback().toSeconds() < 1) {
            throw new IllegalArgumentException("Demand lookback must be between 1 second and 1 hour");
        }
        if (config.getDriverLocationFreshnessSeconds() < 1 || config.getDriverLocationFreshnessSeconds() > 600) {
            throw new IllegalArgumentException("Driver location freshness must be between 1 and 600 seconds");
        }
        if (config.getMinimumDemand() < 1 || config.getMinimumDemand() > 10_000) {
            throw new IllegalArgumentException("Minimum demand must be between 1 and 10000");
        }
        requireRatio(config.getLowRatioThreshold(), "lowRatioThreshold");
        requireRatio(config.getHighRatioThreshold(), "highRatioThreshold");
        if (config.getHighRatioThreshold().compareTo(config.getLowRatioThreshold()) <= 0) {
            throw new IllegalArgumentException("High demand ratio threshold must exceed the low threshold");
        }
        requireMultiplier(config.getModerateMultiplier(), "moderateMultiplier");
        requireMultiplier(config.getHighMultiplier(), "highMultiplier");
        requireMultiplier(config.getMaximumMultiplier(), "maximumMultiplier");
        if (config.getHighMultiplier().compareTo(config.getModerateMultiplier()) < 0
                || config.getHighMultiplier().compareTo(config.getMaximumMultiplier()) > 0
                || config.getModerateMultiplier().compareTo(config.getMaximumMultiplier()) > 0) {
            throw new IllegalArgumentException("Demand/supply tier multipliers must be ordered and within the maximum");
        }
    }

    private void requireRatio(BigDecimal value, String name) {
        if (value == null || value.signum() <= 0 || value.scale() > 4
                || value.precision() - value.scale() > 4) {
            throw new IllegalArgumentException(name + " must be positive with at most four decimal places");
        }
    }

    private void requireMultiplier(BigDecimal value, String name) {
        if (value == null || value.compareTo(BigDecimal.ONE) < 0 || value.scale() > 4
                || value.precision() - value.scale() > 4) {
            throw new IllegalArgumentException(name + " must be at least 1.0000 and fit NUMERIC(8,4)");
        }
    }

    private static final class DurationBounds {
        private static final java.time.Duration MAX_LOOKBACK = java.time.Duration.ofHours(1);
    }

    public record Evaluation(String policyVersion, Instant evaluationTimestamp,
                             String dataStatus, String reason,
                             Long demandCount, Long availableDriverCount,
                             Long eligibleDriverCount, Long freshEligibleDriverCount,
                             int radiusMeters, long demandLookbackSeconds,
                             long driverLocationFreshnessSeconds, int minimumDemand,
                             BigDecimal lowRatioThreshold, BigDecimal highRatioThreshold,
                             BigDecimal moderateMultiplier, BigDecimal highMultiplier,
                             BigDecimal maximumMultiplier, BigDecimal requestedMultiplier,
                             Long effectiveSupplyForRatio) {
        public Evaluation {
            if (policyVersion == null || evaluationTimestamp == null || dataStatus == null || reason == null
                    || lowRatioThreshold == null || highRatioThreshold == null || moderateMultiplier == null
                    || highMultiplier == null || maximumMultiplier == null || requestedMultiplier == null) {
                throw new IllegalArgumentException("Complete demand/supply evaluation is required");
            }
        }
    }
}
