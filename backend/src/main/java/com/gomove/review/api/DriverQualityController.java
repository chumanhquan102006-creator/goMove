package com.gomove.review.api;

import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.review.service.QualityService;
import jakarta.validation.Valid;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/v1/drivers/me/quality-cases")
@PreAuthorize("hasRole('DRIVER')")
public class DriverQualityController {
    private final QualityService quality;

    public DriverQualityController(QualityService quality) { this.quality = quality; }

    @GetMapping
    public ApiResponse<QualityCasePageResponse> cases(@AuthenticationPrincipal CustomUserPrincipal principal,
                                                      @RequestParam(defaultValue = "0") int page,
                                                      @RequestParam(defaultValue = "20") int size) {
        return ApiResponse.success("MY_QUALITY_CASES", "My quality cases",
                quality.ownCases(principal.publicId(), principal.role(), page, size));
    }

    @PostMapping("/{casePublicId}/dispute")
    public ApiResponse<QualityCaseResponse> dispute(@AuthenticationPrincipal CustomUserPrincipal principal,
                                                    @PathVariable UUID casePublicId,
                                                    @Valid @RequestBody QualityDisputeRequest request) {
        return ApiResponse.success("QUALITY_DISPUTE_RECORDED", "Quality dispute recorded",
                quality.dispute(principal.publicId(), principal.role(), casePublicId, request));
    }
}
