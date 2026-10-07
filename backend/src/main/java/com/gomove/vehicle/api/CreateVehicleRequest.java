package com.gomove.vehicle.api;

import com.gomove.vehicle.domain.VehicleType;
import io.swagger.v3.oas.annotations.media.Schema;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

@Schema(description = "Request thêm phương tiện cho tài xế")
public record CreateVehicleRequest(
        @NotBlank
        @Size(max = 20)
        @Schema(description = "Biển số xe", example = "79A-123.45")
        String licensePlate,
        @NotNull
        @Schema(description = "Loại phương tiện")
        VehicleType vehicleType,
        @Size(max = 50)
        @Schema(description = "Hãng xe", example = "Honda")
        String brand,
        @Size(max = 50)
        @Schema(description = "Dòng xe", example = "Wave Alpha")
        String model,
        @Size(max = 30)
        @Schema(description = "Màu xe", example = "Black")
        String color
) {
}
