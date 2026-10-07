package com.gomove.driver.api;

import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.driver.service.DriverService;
import jakarta.validation.Valid;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/v1/drivers")
public class DriverController {
    private final DriverService service;

    public DriverController(DriverService service) {
        this.service = service;
    }

    @PostMapping("/onboarding")
    @PreAuthorize("hasRole('CUSTOMER')")
    public ApiResponse<DriverResponse> onboard(
            @AuthenticationPrincipal CustomUserPrincipal principal,
            @Valid @RequestBody RegisterDriverRequest request
    ) {
        return ApiResponse.success("DRIVER_ONBOARDING_REQUESTED", "Driver onboarding requested",
                DriverResponse.from(service.onboardCurrentCustomer(principal.publicId(), principal.role(), request.licenseNumber())));
    }

    @PatchMapping("/{driverPublicId}/approval-status")
    @PreAuthorize("hasRole('ADMIN')")
    public ApiResponse<DriverResponse> updateApprovalStatus(
            @AuthenticationPrincipal CustomUserPrincipal principal,
            @PathVariable UUID driverPublicId,
            @Valid @RequestBody UpdateApprovalStatusRequest request
    ) {
        return ApiResponse.success("DRIVER_APPROVAL_UPDATED", "Driver approval status updated",
                DriverResponse.from(service.updateApprovalStatusAsAdmin(principal.role(), driverPublicId, request.status())));
    }

    @PatchMapping("/me/operating-status")
    @PreAuthorize("hasRole('DRIVER')")
    public ApiResponse<DriverResponse> setOperatingStatus(
            @AuthenticationPrincipal CustomUserPrincipal principal,
            @Valid @RequestBody SetOperatingStatusRequest request
    ) {
        return ApiResponse.success("DRIVER_OPERATING_UPDATED", "Driver operating status updated",
                DriverResponse.from(service.setOwnOperatingStatus(principal.publicId(), principal.role(), request.status())));
    }
}
