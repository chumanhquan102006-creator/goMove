package com.gomove.geocoding.api;

import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.geocoding.service.GeocodingRateLimiter;
import com.gomove.geocoding.service.GeocodingService;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

@RestController
@RequestMapping("/api/v1/locations")
public class GeocodingController {
    private final GeocodingService service;
    private final GeocodingRateLimiter rateLimiter;

    public GeocodingController(GeocodingService service, GeocodingRateLimiter rateLimiter) {
        this.service = service;
        this.rateLimiter = rateLimiter;
    }

    @GetMapping("/search")
    @PreAuthorize("hasRole('CUSTOMER')")
    public ApiResponse<List<PlaceResponse>> search(@RequestParam(required = false) String q,
                                                    @AuthenticationPrincipal CustomUserPrincipal principal) {
        rateLimiter.check(principal.publicId());
        return ApiResponse.success("PLACES_FOUND", "Places fetched", service.search(q));
    }

    @GetMapping("/reverse")
    @PreAuthorize("hasAnyRole('CUSTOMER', 'DRIVER')")
    public ApiResponse<PlaceResponse> reverse(@RequestParam(required = false) String latitude,
                                              @RequestParam(required = false) String longitude,
                                              @AuthenticationPrincipal CustomUserPrincipal principal) {
        rateLimiter.check(principal.publicId());
        return ApiResponse.success("ADDRESS_RESOLVED", "Address lookup completed",
                service.reverse(latitude, longitude));
    }
}
