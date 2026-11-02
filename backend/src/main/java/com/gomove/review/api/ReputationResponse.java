package com.gomove.review.api;

import java.math.BigDecimal;
import java.util.List;

public record ReputationResponse(BigDecimal ratingAverage, long ratingCount,
                                 long earnedPoints, long deductedPoints,
                                 long availablePoints, List<String> badges) {}
