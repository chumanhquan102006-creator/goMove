package com.gomove.review.api;

import java.time.Instant;
import java.util.UUID;

public record RatingResponse(UUID publicId, UUID bookingPublicId, int stars,
                             String comment, Instant createdAt) {}
