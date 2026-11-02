package com.gomove.admin.api;

import java.time.Instant;
import java.util.List;
import java.util.UUID;
import java.math.BigDecimal;

public record AdminDriver(UUID publicId, UUID userPublicId, String fullName, String phone,
                          String licenseNumber, String approvalStatus, String operatingStatus,
                          int totalTrips, boolean unreleasedBooking, Instant createdAt,
                          List<AdminVehicle> vehicles, BigDecimal ratingAverage,
                          long ratingCount, long availablePoints, boolean qualityFlagged) {}
