package com.gomove.admin.api;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

public record AdminBooking(UUID publicId, UUID customerPublicId, UUID driverPublicId,
                           String status, String vehicleType, BigDecimal finalFare,
                           String currency, String cashStatus, Instant createdAt) {}
