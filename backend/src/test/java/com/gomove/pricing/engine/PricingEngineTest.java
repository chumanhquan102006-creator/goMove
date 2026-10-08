package com.gomove.pricing.engine;

import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.EnumMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

public class PricingEngineTest {
    private static final RouteEstimate ROUTE = new RouteEstimate(
            new BigDecimal("5200"), new BigDecimal("840"), "TEST");

    @Test
    void allVehicleTariffsProduceExactVndFares() {
        PricingEngine engine = new PricingEngine(properties());

        assertThat(engine.calculate(VehicleType.MOTORBIKE, ROUTE).finalFare()).isEqualTo(new BigDecimal("35400.00"));
        assertThat(engine.calculate(VehicleType.CAR_4_SEAT, ROUTE).finalFare()).isEqualTo(new BigDecimal("85400.00"));
        assertThat(engine.calculate(VehicleType.CAR_7_SEAT, ROUTE).finalFare()).isEqualTo(new BigDecimal("115200.00"));
    }

    @Test
    void breakdownIncludesBaseDistanceTimeAndZeroDiscount() {
        FareBreakdown fare = new PricingEngine(properties()).calculate(VehicleType.CAR_4_SEAT, ROUTE);

        assertThat(fare.baseFare()).isEqualTo(new BigDecimal("25000.00"));
        assertThat(fare.distanceFare()).isEqualTo(new BigDecimal("52000.00"));
        assertThat(fare.timeFare()).isEqualTo(new BigDecimal("8400.00"));
        assertThat(fare.surcharge()).isEqualTo(new BigDecimal("0.00"));
        assertThat(fare.discountAmount()).isEqualTo(new BigDecimal("0.00"));
        assertThat(fare.snapshot()).containsEntry("pricePerKm", "10000.00")
                .containsEntry("pricePerMinute", "600.00")
                .containsEntry("pricingEngineVersion", "MVP_V1");
    }

    @Test
    void nonZeroDiscountAndSurgeAreAppliedAfterSubtotal() {
        PricingProperties config = properties();
        config.getTariffs().get(VehicleType.MOTORBIKE).setSurgeMultiplier(new BigDecimal("1.25"));
        FareBreakdown fare = new PricingEngine(config).calculate(
                VehicleType.MOTORBIKE, ROUTE, new BigDecimal("1000.00"));

        assertThat(fare.surgeMultiplier()).isEqualTo(new BigDecimal("1.2500"));
        assertThat(fare.surgeAmount()).isEqualTo(new BigDecimal("8850.00"));
        assertThat(fare.discountAmount()).isEqualTo(new BigDecimal("1000.00"));
        assertThat(fare.finalFare()).isEqualTo(new BigDecimal("43250.00"));
        assertThat(new BigDecimal(fare.snapshot().get("rawSurgedSubtotal")))
                .isEqualByComparingTo(new BigDecimal("44250.00"));
        assertReconciles(fare);
    }

    @Test
    void roundsOnlyFinalFareToWholeVndHalfUp() {
        PricingProperties config = properties();
        PricingProperties.Tariff moto = config.getTariffs().get(VehicleType.MOTORBIKE);
        moto.setBaseFare(new BigDecimal("1.00"));
        moto.setPricePerKm(new BigDecimal("1.00"));
        FareBreakdown fare = new PricingEngine(config).calculate(VehicleType.MOTORBIKE,
                new RouteEstimate(new BigDecimal("500"), new BigDecimal("1"), "TEST"));

        assertThat(fare.distanceFare()).isEqualTo(new BigDecimal("0.50"));
        assertThat(fare.finalFare()).isEqualTo(new BigDecimal("2.00"));
        assertThat(fare.roundingAdjustment()).isEqualTo(new BigDecimal("0.50"));
        assertThat(fare.snapshot()).containsEntry("roundingMode", "HALF_UP");
        assertReconciles(fare);
    }

    @Test
    void negativeAndPositiveRoundingAdjustmentsReconcileDisplayedLines() {
        PricingEngine engine = new PricingEngine(properties());
        FareBreakdown negative = engine.calculate(VehicleType.MOTORBIKE,
                new RouteEstimate(new BigDecimal("1000.111"), new BigDecimal("60"), "TEST"));
        FareBreakdown positive = engine.calculate(VehicleType.MOTORBIKE,
                new RouteEstimate(new BigDecimal("1000.112"), new BigDecimal("60"), "TEST"));

        assertThat(negative.distanceFare()).isEqualTo(new BigDecimal("4500.50"));
        assertThat(negative.finalFare()).isEqualTo(new BigDecimal("16500.00"));
        assertThat(negative.roundingAdjustment()).isEqualTo(new BigDecimal("-0.50"));
        assertThat(new BigDecimal(negative.snapshot().get("rawDistanceFare")))
                .isEqualByComparingTo(new BigDecimal("4500.4995"));
        assertThat(negative.snapshot()).containsEntry("roundingAdjustment", "-0.50");
        assertThat(new BigDecimal(negative.snapshot().get("rawFinalBeforeRounding")))
                .isEqualByComparingTo(new BigDecimal("16500.4995"));
        assertReconciles(negative);

        assertThat(positive.distanceFare()).isEqualTo(new BigDecimal("4500.50"));
        assertThat(positive.finalFare()).isEqualTo(new BigDecimal("16501.00"));
        assertThat(positive.roundingAdjustment()).isEqualTo(new BigDecimal("0.50"));
        assertReconciles(positive);
    }

    @Test
    void surgeAndDiscountUseRawValuesButDisplayedLinesStillReconcile() {
        PricingProperties config = properties();
        config.getTariffs().get(VehicleType.MOTORBIKE).setSurgeMultiplier(new BigDecimal("1.25"));
        FareBreakdown fare = new PricingEngine(config).calculate(VehicleType.MOTORBIKE,
                new RouteEstimate(new BigDecimal("1000.111"), new BigDecimal("60"), "TEST"),
                new BigDecimal("100.25"));

        assertThat(fare.surgeAmount()).isEqualTo(new BigDecimal("4125.12"));
        assertThat(fare.discountAmount()).isEqualTo(new BigDecimal("100.25"));
        assertThat(fare.roundingAdjustment()).isEqualTo(new BigDecimal("-0.37"));
        assertThat(fare.finalFare()).isEqualTo(new BigDecimal("20525.00"));
        assertThat(new BigDecimal(fare.snapshot().get("rawSurgeAmount")))
                .isEqualByComparingTo(new BigDecimal("4125.124875"));
        assertThat(new BigDecimal(fare.snapshot().get("rawFinalBeforeRounding")))
                .isEqualByComparingTo(new BigDecimal("20525.374375"));
        assertReconciles(fare);
    }

    @Test
    void fractionalCentDiscountIsPreservedInSnapshotAndReconciled() {
        FareBreakdown fare = new PricingEngine(properties()).calculate(VehicleType.MOTORBIKE,
                new RouteEstimate(new BigDecimal("1000.111"), new BigDecimal("60"), "TEST"),
                new BigDecimal("100.255"));

        assertThat(fare.discountAmount()).isEqualTo(new BigDecimal("100.26"));
        assertThat(fare.snapshot()).containsEntry("rawDiscountAmount", "100.255")
                .containsEntry("discountAmount", "100.26");
        assertReconciles(fare);
    }

    @Test
    void monetaryAndMultiplierOverflowAreRejectedBeforePersistence() {
        PricingProperties enormousBase = properties();
        enormousBase.getTariffs().get(VehicleType.MOTORBIKE)
                .setBaseFare(new BigDecimal("99999999999999.00"));
        assertThatThrownBy(() -> new PricingEngine(enormousBase).calculate(VehicleType.MOTORBIKE, ROUTE))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("NUMERIC(15,2)");

        PricingProperties enormousMultiplier = properties();
        enormousMultiplier.getTariffs().get(VehicleType.MOTORBIKE)
                .setSurgeMultiplier(new BigDecimal("10000"));
        assertThatThrownBy(() -> new PricingEngine(enormousMultiplier))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("NUMERIC(8,4)");

        assertThatThrownBy(() -> new PricingEngine(properties()).calculate(VehicleType.CAR_7_SEAT,
                new RouteEstimate(new BigDecimal("999999999999.999"), new BigDecimal("60"), "TEST")))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("NUMERIC(15,2)");
    }

    @Test
    void exactDecimalArithmeticAndSameInputsRemainDeterministic() {
        PricingEngine engine = new PricingEngine(properties());
        RouteEstimate route = new RouteEstimate(new BigDecimal("1000.001"),
                new BigDecimal("60.001"), "TEST");

        FareBreakdown first = engine.calculate(VehicleType.CAR_4_SEAT, route);
        FareBreakdown second = engine.calculate(VehicleType.CAR_4_SEAT, route);

        assertThat(first).isEqualTo(second);
        assertThat(new BigDecimal(first.snapshot().get("rawDistanceFare")))
                .isEqualByComparingTo(new BigDecimal("10000.01"));
        assertThat(new BigDecimal(first.snapshot().get("rawTimeFare")))
                .isEqualByComparingTo(new BigDecimal("600.01"));
        assertThat(first.finalFare()).isEqualTo(new BigDecimal("35600.00"));
    }

    @Test
    void negativeTariffAndNonPositiveFinalFareAreRejected() {
        PricingProperties config = properties();
        config.getTariffs().get(VehicleType.MOTORBIKE).setPricePerKm(new BigDecimal("-1"));
        assertThatThrownBy(() -> new PricingEngine(config)).isInstanceOf(IllegalArgumentException.class);

        PricingEngine engine = new PricingEngine(properties());
        assertThatThrownBy(() -> engine.calculate(VehicleType.MOTORBIKE, ROUTE, new BigDecimal("50000")))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> engine.calculate(VehicleType.MOTORBIKE, ROUTE, new BigDecimal("-1")))
                .isInstanceOf(IllegalArgumentException.class);
    }

    public static PricingProperties properties() {
        PricingProperties config = new PricingProperties();
        config.setEngineVersion("MVP_V1");
        Map<VehicleType, PricingProperties.Tariff> tariffs = new EnumMap<>(VehicleType.class);
        tariffs.put(VehicleType.MOTORBIKE, tariff("12000.00", "4500.00", "0.00"));
        tariffs.put(VehicleType.CAR_4_SEAT, tariff("25000.00", "10000.00", "600.00"));
        tariffs.put(VehicleType.CAR_7_SEAT, tariff("35000.00", "13000.00", "900.00"));
        config.setTariffs(tariffs);
        return config;
    }

    private static PricingProperties.Tariff tariff(String base, String perKm, String perMinute) {
        PricingProperties.Tariff tariff = new PricingProperties.Tariff();
        tariff.setBaseFare(new BigDecimal(base));
        tariff.setPricePerKm(new BigDecimal(perKm));
        tariff.setPricePerMinute(new BigDecimal(perMinute));
        tariff.setSurcharge(BigDecimal.ZERO);
        tariff.setSurgeMultiplier(BigDecimal.ONE);
        return tariff;
    }

    private static void assertReconciles(FareBreakdown fare) {
        assertThat(fare.baseFare().add(fare.distanceFare()).add(fare.timeFare())
                .add(fare.surcharge()).add(fare.surgeAmount())
                .subtract(fare.discountAmount()).add(fare.roundingAdjustment()))
                .isEqualTo(fare.finalFare());
    }
}
