package com.gomove.location.api;

import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotNull;

public record UpdateDriverLocationRequest(
        @NotNull
        @DecimalMin("-90.0")
        @DecimalMax("90.0")
        Double latitude,

        @NotNull
        @DecimalMin("-180.0")
        @DecimalMax("180.0")
        Double longitude,

        @DecimalMin("0.0")
        Double accuracy,

        @DecimalMin("0.0")
        @DecimalMax(value = "360.0", inclusive = false)
        Double bearing
) {
}
