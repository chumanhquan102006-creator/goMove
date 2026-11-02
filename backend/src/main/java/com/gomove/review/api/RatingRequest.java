package com.gomove.review.api;

import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.Size;

public record RatingRequest(@Min(1) @Max(5) int stars, @Size(max = 500) String comment) {}
