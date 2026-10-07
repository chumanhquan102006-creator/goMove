package com.gomove.driver.api;

import io.swagger.v3.oas.annotations.media.Schema;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

@Schema(description = "Request đăng ký tài xế")
public record RegisterDriverRequest(
        @NotBlank
        @Size(max = 50)
        @Schema(description = "Số GPLX", example = "79A1-123456")
        String licenseNumber
) {
}
