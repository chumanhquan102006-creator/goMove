package com.gomove.trip.api;

import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.trip.service.TripAction;
import com.gomove.trip.service.TripApplicationService;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

@RestController
@RequestMapping("/api/v1/drivers/me/trips/{bookingPublicId}")
@PreAuthorize("hasRole('DRIVER')")
public class DriverTripController {
    private final TripApplicationService trips;

    public DriverTripController(TripApplicationService trips) { this.trips = trips; }

    @PostMapping("/arrive")
    public ApiResponse<TripTransitionResponse> arrive(@AuthenticationPrincipal CustomUserPrincipal user,
                                                       @PathVariable UUID bookingPublicId) {
        return execute(user, bookingPublicId, TripAction.ARRIVE);
    }

    @PostMapping("/onboard")
    public ApiResponse<TripTransitionResponse> onboard(@AuthenticationPrincipal CustomUserPrincipal user,
                                                        @PathVariable UUID bookingPublicId) {
        return execute(user, bookingPublicId, TripAction.ONBOARD);
    }

    @PostMapping("/start")
    public ApiResponse<TripTransitionResponse> start(@AuthenticationPrincipal CustomUserPrincipal user,
                                                      @PathVariable UUID bookingPublicId) {
        return execute(user, bookingPublicId, TripAction.START);
    }

    @PostMapping("/complete")
    public ApiResponse<TripTransitionResponse> complete(@AuthenticationPrincipal CustomUserPrincipal user,
                                                         @PathVariable UUID bookingPublicId) {
        return execute(user, bookingPublicId, TripAction.COMPLETE);
    }

    private ApiResponse<TripTransitionResponse> execute(CustomUserPrincipal user, UUID bookingPublicId,
                                                        TripAction action) {
        return ApiResponse.success("TRIP_STATUS_CHANGED", "Trip status changed",
                trips.transition(bookingPublicId, user.publicId(), user.role(), action));
    }
}
