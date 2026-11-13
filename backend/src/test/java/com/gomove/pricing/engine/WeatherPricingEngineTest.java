package com.gomove.pricing.engine;

import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.weather.WeatherPricingPolicy;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class WeatherPricingEngineTest {
    private static final RouteEstimate ROUTE = new RouteEstimate(new BigDecimal("1000.111"),
            new BigDecimal("180"), "TEST");
    private static final Instant NOW = Instant.parse("2026-11-12T04:00:00Z");

    @Test
    void appliesWeatherOnlyAndPreservesReconciliationAndAuditSnapshot() {
        FareBreakdown fare = engine(PricingEngineTest.properties()).calculate(VehicleType.MOTORBIKE, ROUTE,
                BigDecimal.ZERO, null, weather("1.1000", "RAIN"), new BigDecimal("1.5000"));

        assertThat(fare.surgeMultiplier()).isEqualByComparingTo("1.1000");
        assertThat(fare.finalFare()).isEqualByComparingTo("18151.00");
        assertThat(fare.snapshot()).containsEntry("preWeatherMultiplier", "1.0000")
                .containsEntry("rawWeatherAdjustedMultiplier", "1.10000000")
                .containsEntry("finalEffectiveMultiplier", "1.1000")
                .containsEntry("requestedWeatherMultiplier", "1.1000")
                .containsEntry("actualMultiplierUplift", "0.1000")
                .containsEntry("weatherPolicyApplied", "true")
                .containsEntry("weatherApplied", "true")
                .containsEntry("weatherUpliftStatus", "FULLY_APPLIED")
                .containsEntry("actualWeatherFareDifferenceVnd", "1651.00")
                .containsEntry("weatherReason", "RAIN")
                .containsEntry("totalSurgeCapApplied", "false");
        assertReconciles(fare);
    }

    @Test
    void composesTariffPeakAndWeatherOnceAndCapsOnlyTheWeatherIncrement() {
        PricingProperties tariff = PricingEngineTest.properties();
        tariff.getTariffs().get(VehicleType.MOTORBIKE).setSurgeMultiplier(new BigDecimal("1.25"));
        PeakHourPricingPolicy.Evaluation peak = new PeakHourPricingPolicy.Evaluation("PEAK_V1", NOW,
                "Asia/Ho_Chi_Minh", new BigDecimal("1.20"), new BigDecimal("1.2000"), true, "PEAK");
        FareBreakdown fare = engine(tariff).calculate(VehicleType.MOTORBIKE, ROUTE, new BigDecimal("100.25"),
                peak, weather("1.1500", "HEAVY_RAIN"), new BigDecimal("1.5000"));

        assertThat(fare.surgeMultiplier()).isEqualByComparingTo("1.5000");
        assertThat(fare.snapshot()).containsEntry("preWeatherMultiplier", "1.5000")
                .containsEntry("rawWeatherAdjustedMultiplier", "1.72500000")
                .containsEntry("finalEffectiveMultiplier", "1.5000")
                .containsEntry("effectiveSurgeMultiplier", "1.5000")
                .containsEntry("requestedWeatherMultiplier", "1.1500")
                .containsEntry("weatherPolicyApplied", "true")
                .containsEntry("weatherApplied", "false")
                .containsEntry("actualMultiplierUplift", "0.0000")
                .containsEntry("weatherUpliftStatus", "FULLY_SUPPRESSED_BY_CAP")
                .containsEntry("weatherRainMm", "0.2")
                .containsEntry("actualWeatherFareDifferenceVnd", "0.00")
                .containsEntry("totalSurgeCapApplied", "true");
        assertReconciles(fare);
    }

    @Test
    void capPartiallyAppliesWeatherUpliftAbovePeakPricing() {
        PeakHourPricingPolicy.Evaluation peak = new PeakHourPricingPolicy.Evaluation("PEAK_V1", NOW,
                "Asia/Ho_Chi_Minh", new BigDecimal("1.40"), new BigDecimal("1.4000"), true, "PEAK");
        FareBreakdown fare = engine(PricingEngineTest.properties()).calculate(VehicleType.MOTORBIKE, ROUTE,
                BigDecimal.ZERO, peak, weather("1.1500", "HEAVY_RAIN"), new BigDecimal("1.5000"));

        assertThat(fare.surgeMultiplier()).isEqualByComparingTo("1.5000");
        assertThat(fare.snapshot()).containsEntry("preWeatherMultiplier", "1.4000")
                .containsEntry("rawWeatherAdjustedMultiplier", "1.61000000")
                .containsEntry("finalEffectiveMultiplier", "1.5000")
                .containsEntry("effectiveSurgeMultiplier", "1.4000")
                .containsEntry("requestedWeatherMultiplier", "1.1500")
                .containsEntry("actualMultiplierUplift", "0.1000")
                .containsEntry("weatherPolicyApplied", "true")
                .containsEntry("weatherApplied", "true")
                .containsEntry("weatherUpliftStatus", "PARTIALLY_CAPPED")
                .containsEntry("actualWeatherFareDifferenceVnd", "1650.00")
                .containsEntry("totalSurgeCapApplied", "true");
        assertReconciles(fare);
    }

    @Test
    void capDoesNotReduceAnExistingTariffPeakMultiplierAlreadyAboveIt() {
        PricingProperties tariff = PricingEngineTest.properties();
        tariff.getTariffs().get(VehicleType.MOTORBIKE).setSurgeMultiplier(new BigDecimal("1.75"));
        FareBreakdown fare = engine(tariff).calculate(VehicleType.MOTORBIKE, ROUTE, BigDecimal.ZERO, null,
                weather("1.1000", "RAIN"), new BigDecimal("1.5000"));

        assertThat(fare.surgeMultiplier()).isEqualByComparingTo("1.7500");
        assertThat(fare.snapshot()).containsEntry("preWeatherMultiplier", "1.7500")
                .containsEntry("requestedWeatherMultiplier", "1.1000")
                .containsEntry("rawWeatherAdjustedMultiplier", "1.92500000")
                .containsEntry("finalEffectiveMultiplier", "1.7500")
                .containsEntry("totalSurgeCapApplied", "true")
                .containsEntry("configuredMaxCombinedMultiplier", "1.5000")
                .containsEntry("weatherApplied", "false")
                .containsEntry("actualMultiplierUplift", "0.0000")
                .containsEntry("weatherUpliftStatus", "FULLY_SUPPRESSED_BY_CAP")
                .containsEntry("actualWeatherFareDifferenceVnd", "0.00");
        assertReconciles(fare);
    }

    @Test
    void roundsCombinedMultiplierToFourDecimalsUsingHalfUpBeforeApplyingFare() {
        PeakHourPricingPolicy.Evaluation peak = new PeakHourPricingPolicy.Evaluation("PEAK_V1", NOW,
                "Asia/Ho_Chi_Minh", new BigDecimal("1.20"), new BigDecimal("1.2000"), true, "PEAK");
        FareBreakdown fare = engine(PricingEngineTest.properties()).calculate(VehicleType.MOTORBIKE, ROUTE,
                BigDecimal.ZERO, peak, weather("1.2346", "RAIN"), new BigDecimal("1.5000"));

        assertThat(fare.snapshot()).containsEntry("rawWeatherAdjustedMultiplier", "1.48152000")
                .containsEntry("finalEffectiveMultiplier", "1.4815")
                .containsEntry("totalSurgeCapApplied", "false");
        assertThat(fare.surgeMultiplier()).isEqualByComparingTo("1.4815");
        assertReconciles(fare);
    }

    @Test
    void featureDisabledWeatherEvaluationKeepsM1FareAndMultiplierBehavior() {
        FareBreakdown m1 = engine(PricingEngineTest.properties()).calculate(VehicleType.MOTORBIKE,
                ROUTE, BigDecimal.ZERO);
        FareBreakdown m2Disabled = engine(PricingEngineTest.properties()).calculate(VehicleType.MOTORBIKE,
                ROUTE, BigDecimal.ZERO, null, weather("1.0000", "FEATURE_DISABLED"), new BigDecimal("1.5000"));

        assertThat(m2Disabled.finalFare()).isEqualByComparingTo(m1.finalFare());
        assertThat(m2Disabled.surgeMultiplier()).isEqualByComparingTo(m1.surgeMultiplier());
        assertThat(m2Disabled.snapshot()).containsEntry("weatherReason", "FEATURE_DISABLED")
                .containsEntry("finalEffectiveMultiplier", "1.0000")
                .containsEntry("requestedWeatherMultiplier", "1.0000")
                .containsEntry("weatherPolicyApplied", "false")
                .containsEntry("weatherApplied", "false")
                .containsEntry("actualMultiplierUplift", "0.0000")
                .containsEntry("weatherUpliftStatus", "NO_UPLIFT_REQUESTED")
                .containsEntry("actualWeatherFareDifferenceVnd", "0.00");
        assertReconciles(m2Disabled);
    }

    @Test
    void noRainRecordsObservationWithoutClaimingAnAppliedUplift() {
        FareBreakdown fare = engine(PricingEngineTest.properties()).calculate(VehicleType.MOTORBIKE, ROUTE,
                BigDecimal.ZERO, null, weather("1.0000", "NO_RAIN"), new BigDecimal("1.5000"));

        assertThat(fare.snapshot()).containsEntry("weatherReason", "NO_RAIN")
                .containsEntry("weatherPolicyApplied", "false")
                .containsEntry("requestedWeatherMultiplier", "1.0000")
                .containsEntry("weatherApplied", "false")
                .containsEntry("actualMultiplierUplift", "0.0000")
                .containsEntry("weatherUpliftStatus", "NO_UPLIFT_REQUESTED")
                .containsEntry("weatherRainMm", "0.1");
        assertReconciles(fare);
    }

    @Test
    void multiplierIncreaseCanProduceNoWholeVndFareDifferenceAfterRounding() {
        PricingProperties tariff = PricingEngineTest.properties();
        PricingProperties.Tariff moto = tariff.getTariffs().get(VehicleType.MOTORBIKE);
        moto.setBaseFare(new BigDecimal("10.00"));
        moto.setPricePerKm(BigDecimal.ZERO);
        RouteEstimate shortRoute = new RouteEstimate(BigDecimal.ONE, BigDecimal.ONE, "TEST");
        FareBreakdown fare = engine(tariff).calculate(VehicleType.MOTORBIKE, shortRoute, BigDecimal.ZERO,
                null, weather("1.0001", "RAIN"), new BigDecimal("1.5000"));

        assertThat(fare.snapshot()).containsEntry("actualMultiplierUplift", "0.0001")
                .containsEntry("weatherApplied", "true")
                .containsEntry("actualWeatherFareDifferenceVnd", "0.00");
        assertThat(fare.finalFare()).isEqualByComparingTo("10.00");
        assertReconciles(fare);
    }

    @Test
    void weatherCompositionWorksForEverySupportedVehicleType() {
        PricingEngine engine = engine(PricingEngineTest.properties());
        for (VehicleType vehicleType : VehicleType.values()) {
            FareBreakdown fare = engine.calculate(vehicleType, ROUTE, BigDecimal.ZERO, null,
                    weather("1.1000", "RAIN"), new BigDecimal("1.5000"));
            assertThat(fare.surgeMultiplier()).isEqualByComparingTo("1.1000");
            assertReconciles(fare);
        }
    }

    @Test
    void invalidMaximumCombinedMultiplierFailsSafely() {
        assertThatThrownBy(() -> engine(PricingEngineTest.properties()).calculate(VehicleType.MOTORBIKE,
                ROUTE, BigDecimal.ZERO, null, weather("1.1000", "RAIN"), new BigDecimal("0.90")))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("Maximum combined multiplier");
    }

    private PricingEngine engine(PricingProperties properties) {
        return new PricingEngine(properties);
    }

    private WeatherPricingPolicy.Evaluation weather(String multiplier, String reason) {
        boolean applied = "RAIN".equals(reason) || "HEAVY_RAIN".equals(reason);
        BigDecimal rainMm = "NO_RAIN".equals(reason) ? new BigDecimal("0.1") : new BigDecimal("0.2");
        return new WeatherPricingPolicy.Evaluation("WEATHER_V1", "OPEN_METEO", NOW, NOW.minusSeconds(300),
                rainMm, 900, "AVAILABLE", "mm", new BigDecimal(multiplier), applied, reason,
                new BigDecimal("0.2"), new BigDecimal("2.0"), new BigDecimal("1.10"), new BigDecimal("1.15"), 1800);
    }

    private void assertReconciles(FareBreakdown fare) {
        assertThat(fare.baseFare().add(fare.distanceFare()).add(fare.timeFare()).add(fare.surcharge())
                .add(fare.surgeAmount()).subtract(fare.discountAmount()).add(fare.roundingAdjustment()))
                .isEqualByComparingTo(fare.finalFare());
    }
}
