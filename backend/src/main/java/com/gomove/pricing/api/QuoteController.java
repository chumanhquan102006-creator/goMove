package com.gomove.pricing.api;

import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.pricing.service.QuoteApplicationService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.media.Content;
import io.swagger.v3.oas.annotations.media.ExampleObject;
import io.swagger.v3.oas.annotations.media.Schema;
import io.swagger.v3.oas.annotations.responses.ApiResponses;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

@RestController
@RequestMapping("/api/v1/quotes")
@PreAuthorize("hasRole('CUSTOMER')")
@SecurityRequirement(name = "BearerAuth")
public class QuoteController {
    private final QuoteApplicationService service;

    public QuoteController(QuoteApplicationService service) {
        this.service = service;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    @Operation(summary = "Create a road-based fare quote",
            description = "CUSTOMER JWT required. The server calls OSRM, prices the route and issues a quote valid for exactly 60 seconds. No quote is created if routing fails.",
            requestBody = @io.swagger.v3.oas.annotations.parameters.RequestBody(
                    content = @Content(schema = @Schema(implementation = CreateQuoteRequest.class),
                            examples = @ExampleObject(value = "{\"pickupLatitude\":21.0287,\"pickupLongitude\":105.8524,\"dropoffLatitude\":21.0245,\"dropoffLongitude\":105.8576,\"vehicleType\":\"MOTORBIKE\"}"))))
    @ApiResponses({
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "201", description = "Quote issued in the standard ApiResponse wrapper"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "400", description = "Invalid request"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "401", description = "Authentication required"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "403", description = "CUSTOMER role required"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "422", description = "No road route"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "502", description = "Invalid routing response"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "503", description = "Routing unavailable")
    })
    public ApiResponse<QuoteResponse> create(
            @AuthenticationPrincipal CustomUserPrincipal principal,
            @Valid @RequestBody CreateQuoteRequest request
    ) {
        return ApiResponse.success("QUOTE_ISSUED", "Quote issued",
                service.create(principal.publicId(), principal.role(), request));
    }

    @GetMapping("/{quotePublicId}")
    @Operation(summary = "Retrieve an owned quote",
            description = "CUSTOMER JWT required. Returns the original fare without repricing. Once server time reaches expiresAt, an unconsumed ISSUED quote is displayed as EXPIRED; its stored status remains ISSUED until a later lifecycle transaction.")
    @ApiResponses({
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "200", description = "Owned quote in the standard ApiResponse wrapper"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "401", description = "Authentication required"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "403", description = "CUSTOMER role required"),
            @io.swagger.v3.oas.annotations.responses.ApiResponse(responseCode = "404", description = "Quote not found for this customer")
    })
    public ApiResponse<QuoteResponse> getOwned(
            @AuthenticationPrincipal CustomUserPrincipal principal,
            @PathVariable UUID quotePublicId
    ) {
        return ApiResponse.success("QUOTE_FETCHED", "Quote fetched",
                service.getOwned(quotePublicId, principal.publicId(), principal.role()));
    }
}
