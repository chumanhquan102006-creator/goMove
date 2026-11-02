package com.gomove.review.api;

import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.review.service.RatingService;
import jakarta.validation.Valid;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/v1/bookings/{bookingPublicId}/rating")
@PreAuthorize("hasRole('CUSTOMER')")
public class RatingController {
    private final RatingService ratings;

    public RatingController(RatingService ratings) { this.ratings = ratings; }

    @PostMapping
    public ApiResponse<RatingResponse> submit(@AuthenticationPrincipal CustomUserPrincipal principal,
                                              @PathVariable UUID bookingPublicId,
                                              @Valid @RequestBody RatingRequest request) {
        return ApiResponse.success("RATING_RECORDED", "Rating recorded",
                ratings.submit(bookingPublicId, principal.publicId(), principal.role(), request));
    }

    @GetMapping
    public ApiResponse<RatingLookupResponse> get(@AuthenticationPrincipal CustomUserPrincipal principal,
                                                 @PathVariable UUID bookingPublicId) {
        return ApiResponse.success("RATING_FETCHED", "Rating fetched",
                ratings.ownedRating(bookingPublicId, principal.publicId(), principal.role()));
    }
}
