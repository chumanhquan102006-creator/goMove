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
        int totalTrips
) {
    public static DriverResponse from(Driver driver) {
        return new DriverResponse(
                driver.getPublicId(),
                driver.getUser().getPublicId(),
                driver.getLicenseNumber(),
                driver.getApprovalStatus().name(),
                driver.getOperatingStatus().name(),
                driver.getRatingAverage(),
                driver.getTotalTrips()
        );
    }
}
