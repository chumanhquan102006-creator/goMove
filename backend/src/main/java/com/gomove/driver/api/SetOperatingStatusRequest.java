package com.gomove.driver.api;

import com.gomove.driver.domain.DriverOperatingStatus;
import io.swagger.v3.oas.annotations.media.Schema;
import jakarta.validation.constraints.NotNull;

@Schema(description = "Request cập nhật trạng thái vận hành tài xế")
public record SetOperatingStatusRequest(
        @NotNull
        @Schema(description = "Trạng thái vận hành mục tiêu")
        DriverOperatingStatus status
) {
}
