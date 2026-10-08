package com.gomove.pricing.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.common.exception.DomainException;
import com.gomove.pricing.api.CreateQuoteRequest;
import com.gomove.pricing.api.QuoteResponse;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.Quote;
import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.engine.FareBreakdown;
import com.gomove.pricing.engine.PricingEngine;
import com.gomove.pricing.routing.RoutingService;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;

import java.time.Clock;
import java.time.Instant;
import java.util.UUID;

@Service
public class QuoteApplicationService {
    private final RoutingService routing;
    private final PricingEngine pricing;
    private final QuotePersistenceService persistence;
    private final Clock clock;

    public QuoteApplicationService(RoutingService routing, PricingEngine pricing,
                                   QuotePersistenceService persistence, Clock clock) {
        this.routing = routing;
        this.pricing = pricing;
        this.persistence = persistence;
        this.clock = clock;
    }

    public QuoteResponse create(UUID customerPublicId, UserRole role, CreateQuoteRequest request) {
        requireCustomer(role);
        GeoCoordinate pickup = new GeoCoordinate(request.getPickupLatitude(), request.getPickupLongitude());
        GeoCoordinate dropoff = new GeoCoordinate(request.getDropoffLatitude(), request.getDropoffLongitude());
        RouteEstimate route = routing.calculateRoute(pickup, dropoff);
        FareBreakdown fare = pricing.calculate(request.getVehicleType(), route);
        Instant issuedAt = clock.instant();
        Quote quote = persistence.create(customerPublicId, pickup, dropoff,
                request.getVehicleType(), route, fare, issuedAt);
        return QuoteResponse.from(quote, clock.instant());
    }

    public QuoteResponse getOwned(UUID quotePublicId, UUID customerPublicId, UserRole role) {
        requireCustomer(role);
        Quote quote = persistence.findOwned(quotePublicId, customerPublicId);
        return QuoteResponse.from(quote, clock.instant());
    }

    private void requireCustomer(UserRole role) {
        if (role != UserRole.CUSTOMER) {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Customer role is required");
        }
    }
}
