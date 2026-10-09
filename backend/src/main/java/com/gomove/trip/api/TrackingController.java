package com.gomove.trip.api;

import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.trip.service.TripApplicationService;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

@RestController
@RequestMapping("/api/v1/bookings/{bookingPublicId}/tracking")
@PreAuthorize("hasAnyRole('CUSTOMER', 'DRIVER')")
public class TrackingController {
    private final TripApplicationService trips;

    public TrackingController(TripApplicationService trips) { this.trips = trips; }

    @GetMapping
    public ApiResponse<TrackingResponse> tracking(@AuthenticationPrincipal CustomUserPrincipal user,
                                                   @PathVariable UUID bookingPublicId) {
        return ApiResponse.success("BOOKING_TRACKING_FETCHED", "Booking tracking fetched",
                trips.tracking(bookingPublicId, user.publicId(), user.role()));
    }
}
