package com.gomove.vehicle.api;

import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.vehicle.service.VehicleService;
import jakarta.validation.Valid;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/v1/drivers/me/vehicles")
@PreAuthorize("hasRole('DRIVER')")
public class VehicleController {
    private final VehicleService service;

    public VehicleController(VehicleService service) {
        this.service = service;
    }

    @PostMapping
    public ApiResponse<VehicleResponse> addVehicle(
            @AuthenticationPrincipal CustomUserPrincipal principal,
            @Valid @RequestBody CreateVehicleRequest request
    ) {
        return ApiResponse.success("VEHICLE_ADDED", "Vehicle added successfully",
                VehicleResponse.from(service.addVehicleForCurrentDriver(principal.publicId(), principal.role(), request)));
    }

    @PatchMapping("/{vehiclePublicId}/activate")
    public ApiResponse<VehicleResponse> setActiveVehicle(
            @AuthenticationPrincipal CustomUserPrincipal principal,
            @PathVariable UUID vehiclePublicId
    ) {
        return ApiResponse.success("VEHICLE_ACTIVATED", "Vehicle activated successfully",
                VehicleResponse.from(service.setActiveVehicleForCurrentDriver(principal.publicId(), principal.role(), vehiclePublicId)));
    }

    @GetMapping
    public ApiResponse<List<VehicleResponse>> listVehicles(@AuthenticationPrincipal CustomUserPrincipal principal) {
        List<VehicleResponse> data = service.findVehiclesForCurrentDriver(principal.publicId(), principal.role()).stream()
                .map(VehicleResponse::from)
                .toList();
        return ApiResponse.success("OK", "Vehicles fetched", data);
    }
}
