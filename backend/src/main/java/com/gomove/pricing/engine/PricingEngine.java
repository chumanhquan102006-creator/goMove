package com.gomove.pricing.engine;

import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.vehicle.domain.VehicleType;
import com.gomove.pricing.weather.WeatherPricingPolicy;
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
        return calculate(vehicleType, route, discountAmount, null);
    }

    public FareBreakdown calculate(VehicleType vehicleType, RouteEstimate route, BigDecimal discountAmount,
                                   PeakHourPricingPolicy.Evaluation peakEvaluation) {
        return calculate(vehicleType, route, discountAmount, peakEvaluation, null, null);
    }

    public FareBreakdown calculate(VehicleType vehicleType, RouteEstimate route, BigDecimal discountAmount,
                                   PeakHourPricingPolicy.Evaluation peakEvaluation,
                                   WeatherPricingPolicy.Evaluation weatherEvaluation,
                                   BigDecimal maximumCombinedMultiplier) {
        if (vehicleType == null || route == null || discountAmount == null || discountAmount.signum() < 0) {
            throw new IllegalArgumentException("Vehicle type, route and non-negative discount are required");
        }
        PricingProperties.Tariff tariff = properties.getTariffs().get(vehicleType);
        if (tariff == null) throw new IllegalArgumentException("No tariff for vehicle type " + vehicleType);

        BigDecimal tariffMultiplier = tariff.getSurgeMultiplier().setScale(4, RoundingMode.UNNECESSARY);
        BigDecimal peakMultiplier = peakEvaluation == null
                ? BigDecimal.ONE.setScale(4) : peakEvaluation.peakMultiplier();
        BigDecimal preWeatherMultiplier = effectiveMultiplier(tariffMultiplier, peakMultiplier);
        WeatherComposition weather = weatherEvaluation == null
                ? WeatherComposition.none(preWeatherMultiplier)
                : composeWeather(preWeatherMultiplier, weatherEvaluation, maximumCombinedMultiplier);
        BigDecimal effectiveMultiplier = weather.finalMultiplier();

        BigDecimal rawDistanceFare = route.distanceMeters()
                .multiply(tariff.getPricePerKm()).divide(THOUSAND, MathContext.DECIMAL128);
        BigDecimal rawTimeFare = route.durationSeconds()
                .multiply(tariff.getPricePerMinute()).divide(SIXTY, MathContext.DECIMAL128);
        BigDecimal rawSubtotal = tariff.getBaseFare().add(rawDistanceFare)
                .add(rawTimeFare).add(tariff.getSurcharge());
        BigDecimal rawSurgeAmount = rawSubtotal.multiply(effectiveMultiplier.subtract(BigDecimal.ONE));
        BigDecimal surgedSubtotal = rawSubtotal.add(rawSurgeAmount);
        BigDecimal rawFinalFare = surgedSubtotal.subtract(discountAmount);
        BigDecimal finalFare = money(rawFinalFare.setScale(0, RoundingMode.HALF_UP));
        if (finalFare.signum() <= 0) throw new IllegalArgumentException("Final fare must remain positive");
        BigDecimal actualWeatherFareDifference = null;
        if (weatherEvaluation != null) {
            BigDecimal fareWithoutWeather = money(rawSubtotal.multiply(preWeatherMultiplier)
                    .subtract(discountAmount).setScale(0, RoundingMode.HALF_UP));
            actualWeatherFareDifference = money(finalFare.subtract(fareWithoutWeather));
        }

        BigDecimal baseFare = money(tariff.getBaseFare());
        BigDecimal distanceFare = money(rawDistanceFare);
        BigDecimal timeFare = money(rawTimeFare);
        BigDecimal surcharge = money(tariff.getSurcharge());
        BigDecimal surgeAmount = money(rawSurgeAmount);
        BigDecimal discount = money(discountAmount);
        BigDecimal multiplier = effectiveMultiplier;
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
        if (peakEvaluation != null) {
            snapshot.put("peakHourPolicyVersion", peakEvaluation.policyVersion());
            snapshot.put("peakHourEvaluationTimestamp", peakEvaluation.timestamp().toString());
            snapshot.put("peakHourTimezone", peakEvaluation.timezone());
            snapshot.put("peakHourMultiplier", peakMultiplier.toPlainString());
            snapshot.put("configuredPeakHourMultiplier", peakEvaluation.configuredPeakMultiplier().toPlainString());
            snapshot.put("peakHourApplied", Boolean.toString(peakEvaluation.applied()));
            snapshot.put("peakHourReason", peakEvaluation.reason());
            snapshot.put("tariffSurgeMultiplier", tariffMultiplier.toPlainString());
            // Preserve the M1 field's meaning: tariff × peak-hour, before any optional M2 signal.
            snapshot.put("effectiveSurgeMultiplier", preWeatherMultiplier.toPlainString());
        }
        if (weatherEvaluation != null) {
            snapshot.put("weatherPricingPolicyVersion", weatherEvaluation.policyVersion());
            snapshot.put("weatherProvider", weatherEvaluation.provider());
            snapshot.put("weatherEvaluationTimestamp", weatherEvaluation.evaluatedAt().toString());
            snapshot.put("weatherObservationTimestamp", weatherEvaluation.observedAt() == null
                    ? "NOT_AVAILABLE" : weatherEvaluation.observedAt().toString());
            snapshot.put("weatherFreshnessSeconds", weatherEvaluation.observedAt() == null
                    || weatherEvaluation.evaluatedAt().isBefore(weatherEvaluation.observedAt())
                    ? "NOT_AVAILABLE" : Long.toString(java.time.Duration.between(
                            weatherEvaluation.observedAt(), weatherEvaluation.evaluatedAt()).toSeconds()));
            snapshot.put("weatherMaximumAgeSeconds", Long.toString(weatherEvaluation.maximumAgeSeconds()));
            snapshot.put("weatherDataStatus", weatherEvaluation.dataStatus());
            snapshot.put("weatherRainMm", weatherEvaluation.rainMm() == null
                    ? "NOT_AVAILABLE" : weatherEvaluation.rainMm().toPlainString());
            snapshot.put("weatherRainUnit", weatherEvaluation.unit());
            snapshot.put("weatherObservationIntervalSeconds", weatherEvaluation.intervalSeconds() == null
                    ? "NOT_AVAILABLE" : weatherEvaluation.intervalSeconds().toString());
            snapshot.put("configuredWeatherMultiplier", weatherEvaluation.multiplier().toPlainString());
            snapshot.put("requestedWeatherMultiplier", weatherEvaluation.multiplier().toPlainString());
            // Retained for compatibility: this legacy field is the policy-requested factor, not the applied uplift.
            snapshot.put("weatherMultiplier", weatherEvaluation.multiplier().toPlainString());
            snapshot.put("weatherPolicyApplied", Boolean.toString(weatherEvaluation.applied()));
            BigDecimal actualMultiplierUplift = effectiveMultiplier.subtract(preWeatherMultiplier);
            if (actualMultiplierUplift.signum() < 0) {
                throw new IllegalStateException("Weather pricing must not reduce the pre-weather multiplier");
            }
            snapshot.put("actualMultiplierUplift", actualMultiplierUplift.toPlainString());
            snapshot.put("weatherApplied", Boolean.toString(actualMultiplierUplift.signum() > 0));
            snapshot.put("weatherUpliftStatus", weatherUpliftStatus(weatherEvaluation, weather, actualMultiplierUplift));
            snapshot.put("actualWeatherFareDifferenceVnd", actualWeatherFareDifference.toPlainString());
            snapshot.put("weatherReason", weatherEvaluation.reason());
            snapshot.put("weatherNoRainBelowMm", weatherEvaluation.noRainBelowMm().toPlainString());
            snapshot.put("weatherHeavyRainFromMm", weatherEvaluation.heavyRainFromMm().toPlainString());
            snapshot.put("configuredRainMultiplier", weatherEvaluation.configuredRainMultiplier().toPlainString());
            snapshot.put("configuredHeavyRainMultiplier", weatherEvaluation.configuredHeavyRainMultiplier().toPlainString());
            snapshot.put("weatherDataAttribution", "Weather data by Open-Meteo.com");
            snapshot.put("weatherDataLicense", "CC BY 4.0");
            snapshot.put("preWeatherMultiplier", preWeatherMultiplier.toPlainString());
            snapshot.put("rawWeatherAdjustedMultiplier", weather.rawRequestedMultiplier().toPlainString());
            snapshot.put("finalEffectiveMultiplier", effectiveMultiplier.toPlainString());
            snapshot.put("configuredMaxCombinedMultiplier", weather.maximumCombinedMultiplier().toPlainString());
            snapshot.put("totalSurgeCapApplied", Boolean.toString(weather.capApplied()));
            snapshot.putIfAbsent("tariffSurgeMultiplier", tariffMultiplier.toPlainString());
            snapshot.putIfAbsent("peakHourMultiplier", peakMultiplier.toPlainString());
            snapshot.putIfAbsent("effectiveSurgeMultiplier", preWeatherMultiplier.toPlainString());
        }

        return new FareBreakdown(properties.getEngineVersion(), "VND", baseFare, distanceFare,
                timeFare, surcharge, multiplier, surgeAmount, discount, roundingAdjustment, finalFare,
                Collections.unmodifiableMap(snapshot));
    }

    private String weatherUpliftStatus(WeatherPricingPolicy.Evaluation evaluation, WeatherComposition weather,
                                       BigDecimal actualMultiplierUplift) {
        if (evaluation.multiplier().compareTo(BigDecimal.ONE) <= 0) return "NO_UPLIFT_REQUESTED";
        if (!weather.capApplied()) return "FULLY_APPLIED";
        return actualMultiplierUplift.signum() > 0 ? "PARTIALLY_CAPPED" : "FULLY_SUPPRESSED_BY_CAP";
    }

    private WeatherComposition composeWeather(BigDecimal preWeatherMultiplier,
                                               WeatherPricingPolicy.Evaluation evaluation,
                                               BigDecimal maximumCombinedMultiplier) {
        BigDecimal weatherMultiplier = evaluation.multiplier();
        if (weatherMultiplier == null || weatherMultiplier.compareTo(BigDecimal.ONE) < 0
                || weatherMultiplier.scale() > 4 || weatherMultiplier.precision() - weatherMultiplier.scale() > 4) {
            throw new IllegalArgumentException("Weather multiplier must fit positive NUMERIC(8,4) and not reduce fares");
        }
        if (maximumCombinedMultiplier == null || maximumCombinedMultiplier.compareTo(BigDecimal.ONE) < 0
                || maximumCombinedMultiplier.scale() > 4
                || maximumCombinedMultiplier.precision() - maximumCombinedMultiplier.scale() > 4) {
            throw new IllegalArgumentException("Maximum combined multiplier must fit NUMERIC(8,4) and be at least 1");
        }
        BigDecimal rawRequested = preWeatherMultiplier.multiply(weatherMultiplier);
        BigDecimal roundedRequested = rawRequested.setScale(4, RoundingMode.HALF_UP);
        boolean capApplied = weatherMultiplier.compareTo(BigDecimal.ONE) > 0
                && rawRequested.compareTo(maximumCombinedMultiplier) > 0;
        BigDecimal finalMultiplier = roundedRequested;
        if (capApplied) {
            // The cap suppresses only the incremental weather uplift; it never reduces M1 pricing.
            finalMultiplier = preWeatherMultiplier.compareTo(maximumCombinedMultiplier) >= 0
                    ? preWeatherMultiplier : maximumCombinedMultiplier;
        }
        return new WeatherComposition(finalMultiplier, rawRequested, maximumCombinedMultiplier, capApplied);
    }

    private record WeatherComposition(BigDecimal finalMultiplier, BigDecimal rawRequestedMultiplier,
                                      BigDecimal maximumCombinedMultiplier, boolean capApplied) {
        static WeatherComposition none(BigDecimal base) {
            return new WeatherComposition(base, base, base, false);
        }
    }

    private BigDecimal money(BigDecimal value) {
        BigDecimal rounded = value.setScale(2, RoundingMode.HALF_UP);
        if (rounded.precision() - rounded.scale() > 13) {
            throw new IllegalArgumentException("Monetary amount exceeds NUMERIC(15,2) storage precision");
        }
        return rounded;
    }

    private BigDecimal effectiveMultiplier(BigDecimal tariffMultiplier, BigDecimal peakMultiplier) {
        BigDecimal effective;
        try {
            effective = tariffMultiplier.multiply(peakMultiplier).setScale(4, RoundingMode.UNNECESSARY);
        } catch (ArithmeticException ex) {
            throw new IllegalArgumentException("Effective surge multiplier must fit NUMERIC(8,4) exactly", ex);
        }
        if (effective.signum() <= 0 || effective.precision() - effective.scale() > 4) {
            throw new IllegalArgumentException("Effective surge multiplier must fit positive NUMERIC(8,4)");
        }
        return effective;
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
