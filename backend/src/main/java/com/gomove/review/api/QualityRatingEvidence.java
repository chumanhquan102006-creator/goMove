package com.gomove.review.api;

import java.time.Instant;
import java.util.UUID;

public record QualityRatingEvidence(UUID bookingPublicId, int stars, String comment,
                                    Instant createdAt) {}
