package com.gomove.pricing.service;

import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.auth.domain.UserRole;
import com.gomove.common.exception.DomainException;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.Quote;
import com.gomove.pricing.domain.QuoteRepository;
import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.engine.FareBreakdown;
import com.gomove.vehicle.domain.VehicleType;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.UUID;

@Service
public class QuotePersistenceService {
    private final QuoteRepository quotes;
    private final UserRepository users;

    public QuotePersistenceService(QuoteRepository quotes, UserRepository users) {
        this.quotes = quotes;
        this.users = users;
    }

    @Transactional
    public Quote create(UUID customerPublicId, GeoCoordinate pickup, GeoCoordinate dropoff,
                        VehicleType vehicleType, RouteEstimate route, FareBreakdown fare, Instant issuedAt) {
        User customer = users.findByPublicId(customerPublicId)
                .orElseThrow(() -> new DomainException(HttpStatus.UNAUTHORIZED, "UNAUTHORIZED", "Authenticated user was not found"));
        if (customer.getRole() != UserRole.CUSTOMER) {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Customer role is required");
        }
        return quotes.saveAndFlush(new Quote(customer, pickup, dropoff, vehicleType, route, fare, issuedAt));
    }

    @Transactional(readOnly = true)
    public Quote findOwned(UUID quotePublicId, UUID customerPublicId) {
        return quotes.findByPublicIdAndCustomerPublicId(quotePublicId, customerPublicId)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND, "QUOTE_NOT_FOUND", "Quote not found"));
    }
}
