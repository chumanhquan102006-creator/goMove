package com.gomove.trip.api;

import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.trip.service.TripEtaService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

@RestController
@RequestMapping("/api/v1/bookings/{bookingPublicId}/eta")
@PreAuthorize("hasAnyRole('CUSTOMER', 'DRIVER')")
@SecurityRequirement(name = "BearerAuth")
public class TripEtaController {
    private final TripEtaService eta;

    public TripEtaController(TripEtaService eta) { this.eta = eta; }

    @GetMapping
    @Operation(summary = "Retrieve a transient road ETA for an authorized trip participant")
    public ApiResponse<TripEtaResponse> get(@AuthenticationPrincipal CustomUserPrincipal user,
                                            @PathVariable UUID bookingPublicId) {
        return ApiResponse.success("TRIP_ETA_FETCHED", "Trip ETA fetched",
                eta.get(bookingPublicId, user.publicId(), user.role()));
    }
}
