package com.gomove.driver.api;

import com.gomove.driver.domain.DriverApprovalStatus;
import io.swagger.v3.oas.annotations.media.Schema;
import jakarta.validation.constraints.NotNull;

@Schema(description = "Request cập nhật trạng thái duyệt hồ sơ tài xế")
public record UpdateApprovalStatusRequest(
        @NotNull
        @Schema(description = "Trạng thái phê duyệt mới")
        DriverApprovalStatus status
) {
}
