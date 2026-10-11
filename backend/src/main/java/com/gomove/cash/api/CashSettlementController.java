package com.gomove.cash.api;

import com.gomove.cash.service.CashSettlementApplicationService;
import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

@RestController
public class CashSettlementController {
    private final CashSettlementApplicationService service;

    public CashSettlementController(CashSettlementApplicationService service) { this.service = service; }

    @PostMapping("/api/v1/drivers/me/trips/{bookingPublicId}/cash/confirm")
    @PreAuthorize("hasRole('DRIVER')")
    public ApiResponse<CashReceiptResponse> confirm(@AuthenticationPrincipal CustomUserPrincipal principal,
                                                     @PathVariable UUID bookingPublicId) {
        return ApiResponse.success("CASH_PAYMENT_CONFIRMED", "Cash collection confirmed; commission accrued",
                service.confirm(bookingPublicId, principal.publicId(), principal.role()));
    }

    @GetMapping("/api/v1/bookings/{bookingPublicId}/payment")
    @PreAuthorize("hasAnyRole('CUSTOMER','DRIVER')")
    public ApiResponse<CashPaymentResponse> payment(@AuthenticationPrincipal CustomUserPrincipal principal,
                                                    @PathVariable UUID bookingPublicId) {
        return ApiResponse.success("CASH_PAYMENT_FETCHED", "Cash payment fetched",
                service.payment(bookingPublicId, principal.publicId(), principal.role()));
    }

    @GetMapping("/api/v1/drivers/me/commissions/summary")
    @PreAuthorize("hasRole('DRIVER')")
    public ApiResponse<CommissionSummaryResponse> summary(@AuthenticationPrincipal CustomUserPrincipal principal) {
        return ApiResponse.success("COMMISSION_RECEIVABLE_FETCHED",
                "Recorded commission owed to the platform; no remittance has been recorded",
                service.summary(principal.publicId(), principal.role()));
    }
}
