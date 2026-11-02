package com.gomove.review.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record QualityActionRequest(@NotBlank String action,
                                   @Size(max = 500) String note) {}
