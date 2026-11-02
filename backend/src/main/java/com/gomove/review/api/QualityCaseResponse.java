package com.gomove.review.api;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

public record QualityCaseResponse(UUID publicId, UUID driverPublicId, String driverDisplayName, String status,
                                  long ratingCount, BigDecimal recentAverage,
                                  String reason, Instant createdAt, Instant updatedAt) {}
