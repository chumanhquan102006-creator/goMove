package com.gomove.booking.api;

import com.gomove.booking.service.BookingRouteService;
import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.pricing.api.RouteResponse;
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
@RequestMapping("/api/v1/bookings")
@SecurityRequirement(name = "BearerAuth")
public class BookingRouteController {
    private final BookingRouteService service;

    public BookingRouteController(BookingRouteService service) {
        this.service = service;
    }

    @GetMapping("/{bookingPublicId}/route")
    @PreAuthorize("hasAnyRole('CUSTOMER','DRIVER')")
    @Operation(summary = "Retrieve the accepted Quote's stored road route",
            description = "Only the Booking customer or assigned driver may read it. Missing historical geometry is UNAVAILABLE; no routing or repricing occurs.")
    public ApiResponse<RouteResponse> getAuthorized(
            @AuthenticationPrincipal CustomUserPrincipal principal,
            @PathVariable UUID bookingPublicId
    ) {
        return ApiResponse.success("BOOKING_ROUTE_FETCHED", "Booking route fetched",
                service.getAuthorized(bookingPublicId, principal.publicId(), principal.role()));
    }
}
