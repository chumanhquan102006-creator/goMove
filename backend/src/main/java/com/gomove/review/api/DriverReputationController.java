package com.gomove.review.api;

import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.review.service.RatingService;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/drivers/me")
@PreAuthorize("hasRole('DRIVER')")
public class DriverReputationController {
    private final RatingService ratings;

    public DriverReputationController(RatingService ratings) { this.ratings = ratings; }

    @GetMapping("/reputation")
    public ApiResponse<ReputationResponse> reputation(@AuthenticationPrincipal CustomUserPrincipal principal) {
        return ApiResponse.success("DRIVER_REPUTATION", "Driver reputation",
                ratings.reputation(principal.publicId(), principal.role()));
    }

    @GetMapping("/rewards")
    public ApiResponse<RewardHistoryResponse> rewards(@AuthenticationPrincipal CustomUserPrincipal principal,
                                                      @RequestParam(defaultValue = "0") int page,
                                                      @RequestParam(defaultValue = "20") int size) {
        return ApiResponse.success("DRIVER_REWARDS", "Driver reward history",
                ratings.rewards(principal.publicId(), principal.role(), page, size));
    }
}
