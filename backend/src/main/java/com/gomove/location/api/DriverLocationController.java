package com.gomove.location.api;

import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.location.service.DriverLocationService;
import jakarta.validation.Valid;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/drivers/me/location")
@PreAuthorize("hasRole('DRIVER')")
public class DriverLocationController {
    private final DriverLocationService service;

    public DriverLocationController(DriverLocationService service) {
        this.service = service;
    }

    @PutMapping
    public ApiResponse<DriverLocationResponse> updateOwnLocation(
            @AuthenticationPrincipal CustomUserPrincipal principal,
            @Valid @RequestBody UpdateDriverLocationRequest request
    ) {
        return ApiResponse.success(
                "DRIVER_LOCATION_UPDATED",
                "Driver location updated",
                DriverLocationResponse.from(service.updateOwnLocation(
                        principal.publicId(),
                        principal.role(),
                        request.latitude(),
                        request.longitude(),
                        request.accuracy(),
                        request.bearing()
                ))
        );
    }
}
