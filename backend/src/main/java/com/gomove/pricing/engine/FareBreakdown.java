package com.gomove.pricing.engine;

import java.math.BigDecimal;
import java.util.Map;

public record FareBreakdown(
        String pricingEngineVersion,
        String currency,
        BigDecimal baseFare,
        BigDecimal distanceFare,
        BigDecimal timeFare,
        BigDecimal surcharge,
        BigDecimal surgeMultiplier,
        BigDecimal surgeAmount,
        BigDecimal discountAmount,
        BigDecimal roundingAdjustment,
        BigDecimal finalFare,
        Map<String, String> snapshot
) {
}
