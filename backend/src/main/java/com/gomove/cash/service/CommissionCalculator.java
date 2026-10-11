package com.gomove.cash.service;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.math.RoundingMode;

@Component
public class CommissionCalculator {
    private final BigDecimal rate;
    private final String policyVersion;

    public CommissionCalculator(@Value("${gomove.cash.commission-rate}") BigDecimal rate,
                                @Value("${gomove.cash.commission-policy-version}") String policyVersion) {
        if (rate == null || rate.signum() < 0 || rate.compareTo(BigDecimal.ONE) > 0
                || rate.scale() > 10 || rate.precision() - rate.scale() > 2) {
            throw new IllegalArgumentException("Commission rate must fit NUMERIC(12,10) and be between 0 and 1");
        }
        if (policyVersion == null || policyVersion.isBlank() || policyVersion.length() > 40) {
            throw new IllegalArgumentException("Commission policy version is required (maximum 40 characters)");
        }
        this.rate = rate.setScale(10, RoundingMode.UNNECESSARY);
        this.policyVersion = policyVersion;
    }

    public Calculation calculate(BigDecimal acceptedFare) {
        if (acceptedFare == null || acceptedFare.signum() <= 0 || acceptedFare.scale() > 2
                || acceptedFare.precision() - acceptedFare.scale() > 13) {
            throw new IllegalArgumentException("Accepted fare must fit positive NUMERIC(15,2)");
        }
        BigDecimal commission = acceptedFare.multiply(rate).setScale(0, RoundingMode.HALF_UP)
                .setScale(2, RoundingMode.UNNECESSARY);
        if (commission.precision() - commission.scale() > 13 || commission.compareTo(acceptedFare) > 0) {
            throw new IllegalArgumentException("Rounded commission exceeds accepted fare or NUMERIC(15,2)");
        }
        return new Calculation(rate, commission, policyVersion);
    }

    public record Calculation(BigDecimal rate, BigDecimal commissionDue, String policyVersion) {}
}
