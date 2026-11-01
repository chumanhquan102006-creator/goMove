package com.gomove.admin.api;

import java.time.Instant;
import java.util.UUID;

public record AdminAccount(UUID publicId, String fullName, String phone, String email,
                           String role, String status, UUID driverPublicId,
                           String driverApprovalStatus, String driverOperatingStatus,
                           boolean activeBooking, Instant lastBookingAt, Instant createdAt) {}
