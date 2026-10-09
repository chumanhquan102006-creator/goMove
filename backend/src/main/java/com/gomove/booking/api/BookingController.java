package com.gomove.booking.api;

import com.gomove.booking.service.BookingApplicationService;
import com.gomove.booking.service.BookingResult;
import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.responses.ApiResponses;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import jakarta.validation.Valid;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

@RestController
@RequestMapping("/api/v1/bookings")
@PreAuthorize("hasRole('CUSTOMER')")
@SecurityRequirement(name = "BearerAuth")
public class BookingController {
    private final BookingApplicationService service;

    public BookingController(BookingApplicationService service) {
        this.service = service;
    }

    @PostMapping
    @Operation(summary = "Create a Booking from an owned, valid Quote",
            description = "Requires CUSTOMER JWT and an Idempotency-Key of 8-128 safe ASCII characters. "
                    + "A successful equivalent retry returns the original 201 response and timestamp. "
                    + "An expired or consumed Quote returns 409; lock waits are bounded to five seconds.")
    @ApiResponses({
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "201", description = "Booking created or original outcome replayed"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "400", description = "Invalid key or request"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "401", description = "Authentication required"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "403", description = "CUSTOMER role required"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "404", description = "Quote not found for this customer"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "409", description = "Quote unavailable or key reused for a different request"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "503", description = "Lock wait exceeded the bounded policy")
    })
    public ResponseEntity<String> create(@AuthenticationPrincipal CustomUserPrincipal principal,
                                         @RequestHeader(value = "Idempotency-Key", required = false) String key,
                                         @Valid @RequestBody CreateBookingRequest request) {
        BookingResult result = service.create(principal.publicId(), principal.role(), request.getQuotePublicId(), key);
        return ResponseEntity.status(result.httpStatus()).contentType(MediaType.APPLICATION_JSON)
                .body(result.responseBody());
    }

    @GetMapping("/{bookingPublicId}")
    @Operation(summary = "Retrieve an owned Booking",
            description = "CUSTOMER JWT required. Returns current persisted status and the original accepted fare.")
    @ApiResponses({
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "200", description = "Owned Booking"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "401", description = "Authentication required"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "403", description = "CUSTOMER role required"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "404", description = "Booking not found for this customer")
    })
    public ApiResponse<BookingResponse> getOwned(@AuthenticationPrincipal CustomUserPrincipal principal,
                                                 @PathVariable UUID bookingPublicId) {
        return ApiResponse.success("BOOKING_FETCHED", "Booking fetched",
                service.getOwned(bookingPublicId, principal.publicId(), principal.role()));
    }
}
