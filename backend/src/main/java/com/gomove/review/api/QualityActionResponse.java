package com.gomove.review.api;

import java.time.Instant;
import java.util.UUID;

public record QualityActionResponse(UUID publicId, String action, String note,
                                    Instant createdAt) {}
