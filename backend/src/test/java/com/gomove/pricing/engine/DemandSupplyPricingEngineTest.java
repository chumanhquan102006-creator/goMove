package com.gomove.pricing.engine;

import com.gomove.pricing.demandsupply.DemandSupplyMetrics;
import com.gomove.pricing.demandsupply.DemandSupplyPricingPolicy;
import com.gomove.pricing.demandsupply.DemandSupplyPricingProperties;
import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.weather.WeatherPricingPolicy;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;

class DemandSupplyPricingEngineTest {
    private static final Instant NOW = Instant.parse("2030-01-01T01:00:00Z");
    private static final RouteEstimate ROUTE = new RouteEstimate(new BigDecimal("1000.111"),
            new BigDecimal("60"), "TEST_ROUTER");

    @Test
    void m2bDisabledProducesExactlyThePreviousM1AndM2aSnapshot() {
        PricingEngine engine = engine();
        PeakHourPricingPolicy.Evaluation peak = peak("1.2000");
        WeatherPricingPolicy.Evaluation weather = weather("1.1000", true, "RAIN");

        FareBreakdown previous = engine.calculate(VehicleType.MOTORBIKE, ROUTE, BigDecimal.ZERO,
                peak, weather, new BigDecimal("1.5000"));
        FareBreakdown withDisabledM2b = engine.calculate(VehicleType.MOTORBIKE, ROUTE, BigDecimal.ZERO,
                peak, null, weather, new BigDecimal("1.5000"));

        assertThat(withDisabledM2b).isEqualTo(previous);
        assertThat(withDisabledM2b.snapshot()).doesNotContainKey("demandSupplyPolicyVersion");
    }

    @Test
    void demandMultiplierIsComposedAfterTariffAndPeakAndBeforeWeather() {
        PricingEngine engine = engine();
        DemandSupplyPricingPolicy.Evaluation demand = demand(4, 2);
        WeatherPricingPolicy.Evaluation weather = weather("1.1500", true, "HEAVY_RAIN");
        FareBreakdown fare = engine.calculate(VehicleType.MOTORBIKE, ROUTE, BigDecimal.ZERO,
                peak("1.2000"), demand, weather, new BigDecimal("1.5000"));

        assertThat(fare.snapshot()).containsEntry("preDemandMultiplier", "1.2000")
                .containsEntry("requestedDemandSupplyMultiplier", "1.1000")
                .containsEntry("preWeatherMultiplier", "1.3200")
                .containsEntry("rawWeatherAdjustedMultiplier", "1.51800000")
                .containsEntry("finalEffectiveMultiplier", "1.5000")
                .containsEntry("effectiveSurgeMultiplier", "1.2000")
                .containsEntry("actualDemandMultiplierUplift", "0.1200")
                .containsEntry("demandSupplyApplied", "true")
                .containsEntry("actualMultiplierUplift", "0.1800")
                .containsEntry("weatherApplied", "true")
                .containsEntry("actualDemandFareDifferenceVnd", "1980.00")
                .containsEntry("actualWeatherFareDifferenceVnd", "2970.00")
                .containsEntry("totalSurgeCapApplied", "true");
        assertReconciles(fare);
    }

    @Test
    void weatherCanBeFullyAppliedAfterDemandWithoutChangingWeatherAttribution() {
        PricingEngine engine = engine();
        DemandSupplyPricingPolicy.Evaluation demand = demand(4, 2);

        FareBreakdown fare = engine.calculate(VehicleType.MOTORBIKE, ROUTE, BigDecimal.ZERO,
                peak("1.0000"), demand, weather("1.1000", true, "RAIN"), new BigDecimal("1.5000"));

        assertThat(fare.snapshot()).containsEntry("preDemandMultiplier", "1.0000")
                .containsEntry("preWeatherMultiplier", "1.1000")
                .containsEntry("finalEffectiveMultiplier", "1.2100")
                .containsEntry("actualDemandMultiplierUplift", "0.1000")
                .containsEntry("actualMultiplierUplift", "0.1100")
                .containsEntry("weatherUpliftStatus", "FULLY_APPLIED")
                .containsEntry("actualDemandFareDifferenceVnd", "1651.00")
                .containsEntry("actualWeatherFareDifferenceVnd", "1815.00");
        assertReconciles(fare);
    }

    @Test
    void m1PlusDemandWithoutWeatherUsesTheSameRoundingAndAuditableMultiplier() {
        PricingEngine engine = engine();
        DemandSupplyPricingPolicy.Evaluation demand = demand(8, 2);

        FareBreakdown fare = engine.calculate(VehicleType.MOTORBIKE, ROUTE, BigDecimal.ZERO,
                peak("1.0001"), demand, null, null);

        assertThat(fare.snapshot()).containsEntry("preDemandMultiplier", "1.0001")
                .containsEntry("requestedDemandSupplyMultiplier", "1.2000")
                .containsEntry("preWeatherMultiplier", "1.2001")
                .containsEntry("actualDemandMultiplierUplift", "0.2000")
                .containsEntry("demandSupplyDataStatus", "AVAILABLE")
                .containsEntry("demandCount", "8")
                .containsEntry("availableDriverCount", "2")
                .containsEntry("effectiveSupplyForRatio", "2")
                .containsEntry("finalEffectiveMultiplier", "1.2001")
                .containsEntry("effectiveSurgeMultiplier", "1.0001");
        assertReconciles(fare);
    }

    @Test
    void multiplierCompositionRoundsHalfUpAndNeverProducesNegativeUplifts() {
        PricingEngine engine = engine();
        DemandSupplyPricingPolicy.Evaluation demand = demand(8, 2);

        FareBreakdown fare = engine.calculate(VehicleType.MOTORBIKE, ROUTE, BigDecimal.ZERO,
                peak("1.0003"), demand, weather("1.0000", false, "NO_RAIN"), new BigDecimal("1.5000"));

        assertThat(fare.snapshot()).containsEntry("preDemandMultiplier", "1.0003")
                .containsEntry("preWeatherMultiplier", "1.2004")
                .containsEntry("actualDemandMultiplierUplift", "0.2001")
                .containsEntry("actualMultiplierUplift", "0.0000")
                .containsEntry("demandSupplyApplied", "true")
                .containsEntry("weatherApplied", "false");
        assertReconciles(fare);
    }

    @Test
    void weatherCapOnlyConstrainsWeatherAndNeverReducesExistingPeakOrDemandPrice() {
        PricingEngine engine = engine();
        DemandSupplyPricingPolicy.Evaluation demand = demand(8, 2);

        FareBreakdown fare = engine.calculate(VehicleType.MOTORBIKE, ROUTE, BigDecimal.ZERO,
                peak("1.2500"), demand, weather("1.1500", true, "RAIN"), new BigDecimal("1.5000"));

        assertThat(fare.snapshot()).containsEntry("preDemandMultiplier", "1.2500")
                .containsEntry("preWeatherMultiplier", "1.5000")
                .containsEntry("requestedDemandSupplyMultiplier", "1.2000")
                .containsEntry("finalEffectiveMultiplier", "1.5000")
                .containsEntry("actualDemandMultiplierUplift", "0.2500")
                .containsEntry("actualMultiplierUplift", "0.0000")
                .containsEntry("weatherApplied", "false")
                .containsEntry("weatherUpliftStatus", "FULLY_SUPPRESSED_BY_CAP")
                .containsEntry("effectiveSurgeMultiplier", "1.2500");
        assertReconciles(fare);
    }

    private PricingEngine engine() {
        return new PricingEngine(PricingEngineTest.properties());
    }

    private DemandSupplyPricingPolicy.Evaluation demand(long demand, long supply) {
        DemandSupplyPricingProperties properties = new DemandSupplyPricingProperties();
        properties.setEnabled(true);
        return new DemandSupplyPricingPolicy(properties).evaluate(NOW,
                DemandSupplyMetrics.available(demand, supply, supply, supply));
    }

    private PeakHourPricingPolicy.Evaluation peak(String multiplier) {
        return new PeakHourPricingPolicy.Evaluation("PEAK_V1", NOW, "Asia/Ho_Chi_Minh",
                new BigDecimal("1.20"), new BigDecimal(multiplier), true, "PEAK_TEST");
    }

    private WeatherPricingPolicy.Evaluation weather(String multiplier, boolean applied, String reason) {
        BigDecimal rain = "NO_RAIN".equals(reason) ? new BigDecimal("0.1")
                : "HEAVY_RAIN".equals(reason) ? new BigDecimal("2.0") : new BigDecimal("0.2");
        return new WeatherPricingPolicy.Evaluation("WEATHER_V1", "OPEN_METEO", NOW, NOW.minusSeconds(60),
                rain, 900, "AVAILABLE", "mm", new BigDecimal(multiplier), applied, reason,
                new BigDecimal("0.2"), new BigDecimal("2.0"), new BigDecimal("1.1000"),
                new BigDecimal("1.1500"), 1800);
    }

    private void assertReconciles(FareBreakdown fare) {
        assertThat(fare.baseFare().add(fare.distanceFare()).add(fare.timeFare()).add(fare.surcharge())
                .add(fare.surgeAmount()).subtract(fare.discountAmount()).add(fare.roundingAdjustment()))
                .isEqualByComparingTo(fare.finalFare());
    }
}
