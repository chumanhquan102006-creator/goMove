package com.gomove.cash;

import com.gomove.cash.service.CommissionCalculator;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class CommissionCalculatorTest {
    @Test
    void exactTwentyPercentForDemonstrationFares() {
        CommissionCalculator calculator = new CommissionCalculator(new BigDecimal("0.20"), "CASH_MVP_V1");
        assertThat(calculator.calculate(new BigDecimal("35400.00")).commissionDue())
                .isEqualByComparingTo("7080.00");
        assertThat(calculator.calculate(new BigDecimal("12000.00")).commissionDue())
                .isEqualByComparingTo("2400.00");
        assertThat(calculator.calculate(new BigDecimal("25000.00")).commissionDue())
                .isEqualByComparingTo("5000.00");
        assertThat(calculator.calculate(new BigDecimal("35000.00")).commissionDue())
                .isEqualByComparingTo("7000.00");
    }

    @Test
    void halfUpAtWholeVndBoundaryWithoutFloatingPointDrift() {
        CommissionCalculator calculator = new CommissionCalculator(new BigDecimal("0.20"), "CASH_MVP_V1");
        assertThat(calculator.calculate(new BigDecimal("2.49")).commissionDue())
                .isEqualByComparingTo("0.00");
        assertThat(calculator.calculate(new BigDecimal("2.50")).commissionDue())
                .isEqualByComparingTo("1.00");
        assertThat(calculator.calculate(new BigDecimal("10.00")).commissionDue())
                .isEqualByComparingTo("2.00");
    }

    @Test
    void zeroAndFullRateRespectBounds() {
        assertThat(new CommissionCalculator(BigDecimal.ZERO, "ZERO")
                .calculate(new BigDecimal("0.01")).commissionDue()).isEqualByComparingTo("0.00");
        assertThat(new CommissionCalculator(BigDecimal.ONE, "FULL")
                .calculate(new BigDecimal("5.00")).commissionDue()).isEqualByComparingTo("5.00");
        assertThatThrownBy(() -> new CommissionCalculator(BigDecimal.ONE, "FULL")
                .calculate(new BigDecimal("0.50"))).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void invalidRatesAndPrecisionFailBeforePersistence() {
        assertThatThrownBy(() -> new CommissionCalculator(new BigDecimal("-0.01"), "BAD"))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new CommissionCalculator(new BigDecimal("1.01"), "BAD"))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new CommissionCalculator(new BigDecimal("0.12345678901"), "BAD"))
                .isInstanceOf(IllegalArgumentException.class);
        CommissionCalculator full = new CommissionCalculator(BigDecimal.ONE, "FULL");
        assertThatThrownBy(() -> full.calculate(new BigDecimal("9999999999999.99")))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> full.calculate(new BigDecimal("10000000000000.00")))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> full.calculate(new BigDecimal("5.001")))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
