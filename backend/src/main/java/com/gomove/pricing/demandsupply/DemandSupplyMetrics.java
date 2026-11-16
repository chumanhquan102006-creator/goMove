package com.gomove.pricing.demandsupply;

/** Aggregate, privacy-safe demand and supply data from one database snapshot. */
public record DemandSupplyMetrics(
        Status status,
        Long demandCount,
        Long availableDriverCount,
        Long eligibleDriverCount,
        Long freshEligibleDriverCount,
        String reason
) {
    public DemandSupplyMetrics {
        if (status == null || reason == null || reason.isBlank()) {
            throw new IllegalArgumentException("Demand/supply metrics status and reason are required");
        }
        if (status == Status.METRICS_UNAVAILABLE) {
            if (demandCount != null || availableDriverCount != null
                    || eligibleDriverCount != null || freshEligibleDriverCount != null) {
                throw new IllegalArgumentException("Unavailable metrics must not report counts as zero");
            }
        } else {
            requireCount(demandCount, "demandCount");
            requireCount(availableDriverCount, "availableDriverCount");
            requireCount(eligibleDriverCount, "eligibleDriverCount");
            requireCount(freshEligibleDriverCount, "freshEligibleDriverCount");
            if (freshEligibleDriverCount > eligibleDriverCount) {
                throw new IllegalArgumentException("Fresh eligible drivers cannot exceed eligible drivers");
            }
        }
    }

    public static DemandSupplyMetrics available(long demand, long supply, long eligible, long freshEligible) {
        Status status = freshEligible < eligible ? Status.LOCATION_DATA_UNRELIABLE : Status.AVAILABLE;
        return new DemandSupplyMetrics(status, demand, supply, eligible, freshEligible,
                status == Status.AVAILABLE ? "SNAPSHOT_AVAILABLE" : "STALE_OR_FUTURE_GPS_NEAR_PICKUP");
    }

    public static DemandSupplyMetrics unavailable() {
        return new DemandSupplyMetrics(Status.METRICS_UNAVAILABLE, null, null, null, null,
                "DATABASE_QUERY_FAILED");
    }

    private static void requireCount(Long value, String field) {
        if (value == null || value < 0) throw new IllegalArgumentException(field + " must be non-negative");
    }

    public enum Status {
        AVAILABLE,
        LOCATION_DATA_UNRELIABLE,
        METRICS_UNAVAILABLE
    }
}
