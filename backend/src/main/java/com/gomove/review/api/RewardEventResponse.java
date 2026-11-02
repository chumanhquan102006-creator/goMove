package com.gomove.review.api;

import java.time.Instant;
import java.util.UUID;

public record RewardEventResponse(UUID publicId, UUID bookingPublicId, int stars,
                                  int pointsDelta, Instant createdAt) {}
