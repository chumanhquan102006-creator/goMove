package com.gomove.pricing.engine;

import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class PeakHourPricingEngineTest {
    private static final Instant PEAK = Instant.parse("2026-10-05T00:30:00Z");
    private static final RouteEstimate ROUTE = new RouteEstimate(
            new BigDecimal("5200"), new BigDecimal("840"), "TEST");

    @Test
    void composesTariffAndPeakMultipliersAndAppliesTheEffectiveMultiplierOnce() {
        PricingProperties tariffs = PricingEngineTest.properties();
        tariffs.getTariffs().get(VehicleType.MOTORBIKE).setSurgeMultiplier(new BigDecimal("1.25"));
        PeakHourPricingPolicy.Evaluation peak = evaluation(new BigDecimal("1.2000"), true);

        FareBreakdown fare = new PricingEngine(tariffs).calculate(
                VehicleType.MOTORBIKE, ROUTE, BigDecimal.ZERO, peak);

        assertThat(fare.surgeMultiplier()).isEqualTo(new BigDecimal("1.5000"));
        assertThat(fare.surgeAmount()).isEqualTo(new BigDecimal("17700.00"));
        assertThat(fare.finalFare()).isEqualTo(new BigDecimal("53100.00"));
        assertThat(fare.snapshot()).containsEntry("tariffSurgeMultiplier", "1.2500")
                .containsEntry("peakHourMultiplier", "1.2000")
                .containsEntry("configuredPeakHourMultiplier", "1.20")
                .containsEntry("effectiveSurgeMultiplier", "1.5000")
                .containsEntry("surgeMultiplier", "1.5000")
                .containsEntry("peakHourEvaluationTimestamp", PEAK.toString());
        assertReconciles(fare);
    }

    @Test
    void composesPeakWithDiscountAndFractionalFareWithoutBreakingReconciliation() {
        PricingProperties tariffs = PricingEngineTest.properties();
        tariffs.getTariffs().get(VehicleType.MOTORBIKE).setSurgeMultiplier(new BigDecimal("1.25"));
        FareBreakdown fare = new PricingEngine(tariffs).calculate(VehicleType.MOTORBIKE,
                new RouteEstimate(new BigDecimal("1000.111"), new BigDecimal("60"), "TEST"),
                new BigDecimal("100.255"), evaluation(new BigDecimal("1.2000"), true));

        assertThat(fare.surgeMultiplier()).isEqualTo(new BigDecimal("1.5000"));
        assertThat(fare.snapshot()).containsEntry("rawDiscountAmount", "100.255")
                .containsEntry("peakHourReason", "WEEKDAY_MORNING_PEAK");
        assertReconciles(fare);
    }

    @Test
    void disabledPeakEvaluationRetainsExistingTariffCalculation() {
        PricingProperties tariffs = PricingEngineTest.properties();
        tariffs.getTariffs().get(VehicleType.MOTORBIKE).setSurgeMultiplier(new BigDecimal("1.25"));
        FareBreakdown fare = new PricingEngine(tariffs).calculate(VehicleType.MOTORBIKE, ROUTE,
                BigDecimal.ZERO, evaluation(new BigDecimal("1.0000"), false));

        assertThat(fare.surgeMultiplier()).isEqualTo(new BigDecimal("1.2500"));
        assertThat(fare.finalFare()).isEqualTo(new BigDecimal("44250.00"));
        assertThat(fare.snapshot()).containsEntry("peakHourApplied", "false")
                .containsEntry("peakHourMultiplier", "1.0000")
                .containsEntry("effectiveSurgeMultiplier", "1.2500");
        assertReconciles(fare);
    }

    @Test
    void effectiveMultiplierPrecisionAndStorageOverflowFailSafely() {
        PricingProperties inexactProduct = PricingEngineTest.properties();
        inexactProduct.getTariffs().get(VehicleType.MOTORBIKE).setSurgeMultiplier(new BigDecimal("1.1111"));
        assertThatThrownBy(() -> new PricingEngine(inexactProduct).calculate(VehicleType.MOTORBIKE,
                ROUTE, BigDecimal.ZERO, evaluation(new BigDecimal("1.2000"), true)))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("exactly");

        PricingProperties overflow = PricingEngineTest.properties();
        overflow.getTariffs().get(VehicleType.MOTORBIKE).setSurgeMultiplier(new BigDecimal("9999.0000"));
        assertThatThrownBy(() -> new PricingEngine(overflow).calculate(VehicleType.MOTORBIKE,
                ROUTE, BigDecimal.ZERO, evaluation(new BigDecimal("1.2000"), true)))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("NUMERIC(8,4)");
    }

    @Test
    void everyVehicleTypeAcceptsConfiguredPeakMultiplier() {
        PricingEngine engine = new PricingEngine(PricingEngineTest.properties());
        for (VehicleType vehicleType : VehicleType.values()) {
            FareBreakdown fare = engine.calculate(vehicleType, ROUTE, BigDecimal.ZERO,
                    evaluation(new BigDecimal("1.2000"), true));
            assertThat(fare.surgeMultiplier()).isEqualTo(new BigDecimal("1.2000"));
            assertReconciles(fare);
        }
    }

    private PeakHourPricingPolicy.Evaluation evaluation(BigDecimal peakMultiplier, boolean applied) {
        return new PeakHourPricingPolicy.Evaluation("PEAK_HOUR_V1", PEAK, "Asia/Ho_Chi_Minh",
                new BigDecimal("1.20"), peakMultiplier, applied,
                applied ? "WEEKDAY_MORNING_PEAK" : "FEATURE_DISABLED");
    }

    private void assertReconciles(FareBreakdown fare) {
        assertThat(fare.baseFare().add(fare.distanceFare()).add(fare.timeFare()).add(fare.surcharge())
                .add(fare.surgeAmount()).subtract(fare.discountAmount()).add(fare.roundingAdjustment()))
                .isEqualByComparingTo(fare.finalFare());
    }
}
