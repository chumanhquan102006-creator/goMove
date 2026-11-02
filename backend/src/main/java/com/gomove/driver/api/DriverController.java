package com.gomove.driver.api;

import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.driver.service.DriverService;
import com.gomove.driver.domain.Driver;
import com.gomove.review.service.RatingService;
import jakarta.validation.Valid;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/v1/drivers")
public class DriverController {
    private final DriverService service;
    private final RatingService ratings;

    public DriverController(DriverService service, RatingService ratings) {
        this.service = service;
        this.ratings = ratings;
    }

    @PostMapping("/onboarding")
    @PreAuthorize("hasRole('CUSTOMER')")
    public ApiResponse<DriverResponse> onboard(
            @AuthenticationPrincipal CustomUserPrincipal principal,
            @Valid @RequestBody RegisterDriverRequest request
    ) {
        return ApiResponse.success("DRIVER_ONBOARDING_REQUESTED", "Driver onboarding requested",
                response(service.onboardCurrentCustomer(principal.publicId(), principal.role(), request.licenseNumber())));
    }

    @PatchMapping("/{driverPublicId}/approval-status")
    @PreAuthorize("hasRole('ADMIN')")
    public ApiResponse<DriverResponse> updateApprovalStatus(
            @AuthenticationPrincipal CustomUserPrincipal principal,
            @PathVariable UUID driverPublicId,
            @Valid @RequestBody UpdateApprovalStatusRequest request
    ) {
        return ApiResponse.success("DRIVER_APPROVAL_UPDATED", "Driver approval status updated",
                response(service.updateApprovalStatusAsAdmin(principal.publicId(), principal.role(),
                        driverPublicId, request.status())));
    }

    @PatchMapping("/me/operating-status")
    @PreAuthorize("hasRole('DRIVER')")
    public ApiResponse<DriverResponse> setOperatingStatus(
            @AuthenticationPrincipal CustomUserPrincipal principal,
            @Valid @RequestBody SetOperatingStatusRequest request
    ) {
        return ApiResponse.success("DRIVER_OPERATING_UPDATED", "Driver operating status updated",
                response(service.setOwnOperatingStatus(principal.publicId(), principal.role(), request.status())));
    }

    private DriverResponse response(Driver driver) {
        var reputation = ratings.reputationForDriver(driver.getId());
        return DriverResponse.from(driver, reputation.ratingAverage(), reputation.ratingCount());
    }
}
