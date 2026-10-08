package com.gomove.pricing.engine;

import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.vehicle.domain.VehicleType;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.math.MathContext;
import java.math.RoundingMode;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

@Component
public class PricingEngine {
    private static final BigDecimal THOUSAND = BigDecimal.valueOf(1_000);
    private static final BigDecimal SIXTY = BigDecimal.valueOf(60);
    private final PricingProperties properties;

    public PricingEngine(PricingProperties properties) {
        this.properties = properties;
        validateConfiguration();
    }

    public FareBreakdown calculate(VehicleType vehicleType, RouteEstimate route) {
        return calculate(vehicleType, route, BigDecimal.ZERO);
    }

    public FareBreakdown calculate(VehicleType vehicleType, RouteEstimate route, BigDecimal discountAmount) {
        if (vehicleType == null || route == null || discountAmount == null || discountAmount.signum() < 0) {
            throw new IllegalArgumentException("Vehicle type, route and non-negative discount are required");
        }
        PricingProperties.Tariff tariff = properties.getTariffs().get(vehicleType);
        if (tariff == null) throw new IllegalArgumentException("No tariff for vehicle type " + vehicleType);

        BigDecimal rawDistanceFare = route.distanceMeters()
                .multiply(tariff.getPricePerKm()).divide(THOUSAND, MathContext.DECIMAL128);
        BigDecimal rawTimeFare = route.durationSeconds()
                .multiply(tariff.getPricePerMinute()).divide(SIXTY, MathContext.DECIMAL128);
        BigDecimal rawSubtotal = tariff.getBaseFare().add(rawDistanceFare)
                .add(rawTimeFare).add(tariff.getSurcharge());
        BigDecimal rawSurgeAmount = rawSubtotal.multiply(tariff.getSurgeMultiplier().subtract(BigDecimal.ONE));
        BigDecimal surgedSubtotal = rawSubtotal.add(rawSurgeAmount);
        BigDecimal rawFinalFare = surgedSubtotal.subtract(discountAmount);
        BigDecimal finalFare = money(rawFinalFare.setScale(0, RoundingMode.HALF_UP));
        if (finalFare.signum() <= 0) throw new IllegalArgumentException("Final fare must remain positive");

        BigDecimal baseFare = money(tariff.getBaseFare());
        BigDecimal distanceFare = money(rawDistanceFare);
        BigDecimal timeFare = money(rawTimeFare);
        BigDecimal surcharge = money(tariff.getSurcharge());
        BigDecimal surgeAmount = money(rawSurgeAmount);
        BigDecimal discount = money(discountAmount);
        BigDecimal multiplier = tariff.getSurgeMultiplier().setScale(4, RoundingMode.UNNECESSARY);
        BigDecimal displayedSubtotal = baseFare.add(distanceFare).add(timeFare).add(surcharge);
        BigDecimal displayedBeforeAdjustment = displayedSubtotal.add(surgeAmount).subtract(discount);
        // Reconcile independently rounded display lines with the fare rounded from raw values.
        BigDecimal roundingAdjustment = money(finalFare.subtract(displayedBeforeAdjustment));

        Map<String, String> snapshot = new LinkedHashMap<>();
        snapshot.put("pricingEngineVersion", properties.getEngineVersion());
        snapshot.put("currency", "VND");
        snapshot.put("vehicleType", vehicleType.name());
        snapshot.put("distanceMeters", route.distanceMeters().toPlainString());
        snapshot.put("durationSeconds", route.durationSeconds().toPlainString());
        snapshot.put("baseFare", baseFare.toPlainString());
        snapshot.put("pricePerKm", money(tariff.getPricePerKm()).toPlainString());
        snapshot.put("pricePerMinute", money(tariff.getPricePerMinute()).toPlainString());
        snapshot.put("distanceFare", distanceFare.toPlainString());
        snapshot.put("timeFare", timeFare.toPlainString());
        snapshot.put("rawDistanceFare", rawDistanceFare.toPlainString());
        snapshot.put("rawTimeFare", rawTimeFare.toPlainString());
        snapshot.put("rawSubtotal", rawSubtotal.toPlainString());
        snapshot.put("rawSurgeAmount", rawSurgeAmount.toPlainString());
        snapshot.put("rawSurgedSubtotal", surgedSubtotal.toPlainString());
        snapshot.put("rawFinalBeforeRounding", rawFinalFare.toPlainString());
        snapshot.put("surcharge", surcharge.toPlainString());
        snapshot.put("surgeMultiplier", multiplier.toPlainString());
        snapshot.put("surgeAmount", surgeAmount.toPlainString());
        snapshot.put("rawDiscountAmount", discountAmount.toPlainString());
        snapshot.put("discountAmount", discount.toPlainString());
        snapshot.put("displayedSubtotal", displayedSubtotal.toPlainString());
        snapshot.put("displayedBeforeAdjustment", displayedBeforeAdjustment.toPlainString());
        snapshot.put("roundingAdjustment", roundingAdjustment.toPlainString());
        snapshot.put("finalFare", finalFare.toPlainString());
        snapshot.put("roundingMode", RoundingMode.HALF_UP.name());

        return new FareBreakdown(properties.getEngineVersion(), "VND", baseFare, distanceFare,
                timeFare, surcharge, multiplier, surgeAmount, discount, roundingAdjustment, finalFare,
                Collections.unmodifiableMap(snapshot));
    }

    private BigDecimal money(BigDecimal value) {
        BigDecimal rounded = value.setScale(2, RoundingMode.HALF_UP);
        if (rounded.precision() - rounded.scale() > 13) {
            throw new IllegalArgumentException("Monetary amount exceeds NUMERIC(15,2) storage precision");
        }
        return rounded;
    }

    private void validateConfiguration() {
        if (properties.getEngineVersion() == null || properties.getEngineVersion().isBlank()) {
            throw new IllegalArgumentException("Pricing engine version is required");
        }
        if (properties.getTariffs() == null) throw new IllegalArgumentException("Pricing tariffs are required");
        for (VehicleType type : VehicleType.values()) {
            PricingProperties.Tariff tariff = properties.getTariffs().get(type);
            if (tariff == null) throw new IllegalArgumentException("Missing tariff for " + type);
            requireNonNegative(tariff.getBaseFare(), "baseFare");
            requireNonNegative(tariff.getPricePerKm(), "pricePerKm");
            requireNonNegative(tariff.getPricePerMinute(), "pricePerMinute");
            requireNonNegative(tariff.getSurcharge(), "surcharge");
            if (tariff.getSurgeMultiplier() == null || tariff.getSurgeMultiplier().signum() <= 0
                    || tariff.getSurgeMultiplier().scale() > 4
                    || tariff.getSurgeMultiplier().precision() - tariff.getSurgeMultiplier().scale() > 4) {
                throw new IllegalArgumentException("surgeMultiplier must fit positive NUMERIC(8,4)");
            }
        }
    }

    private void requireNonNegative(BigDecimal value, String name) {
        if (value == null || value.signum() < 0 || value.scale() > 2) {
            throw new IllegalArgumentException(name + " must be non-negative with at most two decimals");
        }
    }
}
