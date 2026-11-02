package com.gomove.driver.api;

import com.gomove.driver.domain.Driver;
import java.math.BigDecimal;
import java.util.UUID;

public record DriverResponse(
        UUID publicId,
        UUID userPublicId,
        String licenseNumber,
        String approvalStatus,
        String operatingStatus,
        BigDecimal ratingAverage,
        long ratingCount,
        int totalTrips
) {
    public static DriverResponse from(Driver driver, BigDecimal verifiedAverage, long ratingCount) {
        return new DriverResponse(
                driver.getPublicId(),
                driver.getUser().getPublicId(),
                driver.getLicenseNumber(),
                driver.getApprovalStatus().name(),
                driver.getOperatingStatus().name(),
                verifiedAverage,
                ratingCount,
                driver.getTotalTrips()
        );
    }
}
