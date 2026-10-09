package com.gomove.dispatch.api;

import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.dispatch.service.DriverOfferService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/v1/drivers/me/offers")
@PreAuthorize("hasRole('DRIVER')")
@SecurityRequirement(name = "BearerAuth")
public class DriverOfferController {
    private final DriverOfferService service;

    public DriverOfferController(DriverOfferService service) { this.service = service; }

    @GetMapping("/active")
    @Operation(summary = "List this driver's unexpired pending offers")
    public ApiResponse<List<DriverOfferResponse>> active(@AuthenticationPrincipal CustomUserPrincipal principal) {
        return ApiResponse.success("ACTIVE_OFFERS_FETCHED", "Active offers fetched",
                service.active(principal.publicId(), principal.role()));
    }

    @PostMapping("/{offerPublicId}/accept")
    @Operation(summary = "Atomically accept an unexpired offer",
            description = "Repeated or competing acceptance returns 409; an offer expires at exactly expiresAt.")
    public ApiResponse<OfferDecisionResponse> accept(@AuthenticationPrincipal CustomUserPrincipal principal,
                                                      @PathVariable UUID offerPublicId) {
        return ApiResponse.success("OFFER_ACCEPTED", "Offer accepted",
                service.accept(principal.publicId(), principal.role(), offerPublicId));
    }

    @PostMapping("/{offerPublicId}/reject")
    @Operation(summary = "Reject an unexpired offer so dispatch can advance")
    public ApiResponse<OfferDecisionResponse> reject(@AuthenticationPrincipal CustomUserPrincipal principal,
                                                      @PathVariable UUID offerPublicId) {
        return ApiResponse.success("OFFER_REJECTED", "Offer rejected",
                service.reject(principal.publicId(), principal.role(), offerPublicId));
    }
}
