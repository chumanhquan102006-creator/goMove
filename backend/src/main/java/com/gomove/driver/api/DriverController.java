package com.gomove.driver.api;

import com.gomove.common.api.ApiResponse;
import com.gomove.driver.service.DriverService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.media.Content;
import io.swagger.v3.oas.annotations.media.Schema;
import io.swagger.v3.oas.annotations.responses.ApiResponses;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/v1/drivers")
@Tag(name = "Driver", description = "Driver management APIs")
public class DriverController {
    private final DriverService service;

    public DriverController(DriverService service) {
        this.service = service;
    }

    @PostMapping("/register")
    @Operation(summary = "Register driver profile from user")
    @ApiResponses({
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "200", description = "Driver registered"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "409", description = "Conflict", content = @Content(schema = @Schema(hidden = true)))
    })
    public ApiResponse<DriverResponse> registerDriver(@Valid @RequestBody RegisterDriverRequest request) {
        return ApiResponse.success("DRIVER_REGISTERED", "Driver registered successfully",
                DriverResponse.from(service.registerDriver(request.userId(), request.licenseNumber())));
    }

    @PatchMapping("/{driverPublicId}/approval-status")
    @Operation(summary = "Update driver approval status")
    @ApiResponses({
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "200", description = "Approval status updated"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "404", description = "Driver not found", content = @Content(schema = @Schema(hidden = true)))
    })
    public ApiResponse<DriverResponse> updateApprovalStatus(
            @PathVariable UUID driverPublicId,
            @Valid @RequestBody UpdateApprovalStatusRequest request
    ) {
        return ApiResponse.success("DRIVER_APPROVAL_UPDATED", "Driver approval status updated",
                DriverResponse.from(service.updateApprovalStatus(driverPublicId, request.status())));
    }

    @PatchMapping("/{driverPublicId}/operating-status")
    @Operation(summary = "Update driver operating status")
    @ApiResponses({
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "200", description = "Operating status updated"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "400", description = "Business rule violation", content = @Content(schema = @Schema(hidden = true))),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "404", description = "Driver not found", content = @Content(schema = @Schema(hidden = true)))
    })
    public ApiResponse<DriverResponse> setOperatingStatus(
            @PathVariable UUID driverPublicId,
            @Valid @RequestBody SetOperatingStatusRequest request
    ) {
        return ApiResponse.success("DRIVER_OPERATING_UPDATED", "Driver operating status updated",
                DriverResponse.from(service.setOperatingStatus(driverPublicId, request.status())));
    }
}
