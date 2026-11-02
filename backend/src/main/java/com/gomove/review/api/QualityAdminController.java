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
@RequestMapping("/api/v1/admin/quality-cases")
@PreAuthorize("hasRole('ADMIN')")
public class QualityAdminController {
    private final QualityService quality;

    public QualityAdminController(QualityService quality) { this.quality = quality; }

    @GetMapping
    public ApiResponse<QualityCasePageResponse> cases(@AuthenticationPrincipal CustomUserPrincipal principal,
                                                      @RequestParam(required = false) String status,
                                                      @RequestParam(defaultValue = "0") int page,
                                                      @RequestParam(defaultValue = "20") int size) {
        return ApiResponse.success("QUALITY_CASES", "Driver quality cases",
                quality.adminCases(principal.role(), status, page, size));
    }

    @GetMapping("/{casePublicId}")
    public ApiResponse<QualityCaseDetailResponse> detail(@AuthenticationPrincipal CustomUserPrincipal principal,
                                                         @PathVariable UUID casePublicId) {
        return ApiResponse.success("QUALITY_CASE", "Driver quality case",
                quality.adminDetail(principal.role(), casePublicId));
    }

    @PostMapping("/{casePublicId}/actions")
    public ApiResponse<QualityCaseDetailResponse> action(@AuthenticationPrincipal CustomUserPrincipal principal,
                                                         @PathVariable UUID casePublicId,
                                                         @Valid @RequestBody QualityActionRequest request) {
        return ApiResponse.success("QUALITY_ACTION_RECORDED", "Quality action recorded",
                quality.adminAction(principal.publicId(), principal.role(), casePublicId, request));
    }
}
