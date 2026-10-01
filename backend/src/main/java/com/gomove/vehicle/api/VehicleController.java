package com.gomove.vehicle.api;

import com.gomove.common.api.ApiResponse;
import com.gomove.vehicle.service.VehicleService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.media.Content;
import io.swagger.v3.oas.annotations.media.Schema;
import io.swagger.v3.oas.annotations.responses.ApiResponses;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/v1/drivers/{driverPublicId}/vehicles")
@Tag(name = "Vehicle", description = "Vehicle management APIs")
public class VehicleController {
    private final VehicleService service;

    public VehicleController(VehicleService service) {
        this.service = service;
    }

    @PostMapping
    @Operation(summary = "Add a vehicle for a driver")
    @ApiResponses({
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "200", description = "Vehicle added"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "404", description = "Driver not found", content = @Content(schema = @Schema(hidden = true))),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "409", description = "License plate exists", content = @Content(schema = @Schema(hidden = true)))
    })
    public ApiResponse<VehicleResponse> addVehicle(
            @PathVariable UUID driverPublicId,
            @Valid @RequestBody CreateVehicleRequest request
    ) {
        return ApiResponse.success("VEHICLE_ADDED", "Vehicle added successfully",
                VehicleResponse.from(service.addVehicle(driverPublicId, request)));
    }

    @PatchMapping("/{vehiclePublicId}/activate")
    @Operation(summary = "Set one active vehicle for driver")
    @ApiResponses({
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "200", description = "Vehicle activated"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "404", description = "Driver/vehicle not found", content = @Content(schema = @Schema(hidden = true)))
    })
    public ApiResponse<VehicleResponse> setActiveVehicle(
            @PathVariable UUID driverPublicId,
            @PathVariable UUID vehiclePublicId
    ) {
        return ApiResponse.success("VEHICLE_ACTIVATED", "Vehicle activated successfully",
                VehicleResponse.from(service.setActiveVehicle(driverPublicId, vehiclePublicId)));
    }

    @GetMapping
    @Operation(summary = "List vehicles by driver")
    public ApiResponse<List<VehicleResponse>> listVehicles(@PathVariable UUID driverPublicId) {
        List<VehicleResponse> data = service.findByDriverPublicId(driverPublicId).stream().map(VehicleResponse::from).toList();
        return ApiResponse.success("OK", "Vehicles fetched", data);
    }
}
