package com.gomove.review.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record QualityDisputeRequest(@NotBlank @Size(max = 500) String reason) {}
