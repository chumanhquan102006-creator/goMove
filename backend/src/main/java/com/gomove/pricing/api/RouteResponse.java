package com.gomove.pricing.api;

import com.gomove.pricing.domain.Quote;
import com.gomove.pricing.domain.RouteGeometry;

import java.time.Instant;
import java.util.UUID;

/** A read-only view of the road geometry captured with a Quote. */
public record RouteResponse(
        UUID sourceQuotePublicId,
        UUID bookingPublicId,
        Availability availability,
        String geometryFormat,
        RouteGeometry geometry,
        String routingProvider,
        Instant capturedAt,
        String unavailableReason
) {
    public enum Availability { AVAILABLE, UNAVAILABLE }

    public static RouteResponse from(Quote quote, UUID bookingPublicId) {
        RouteGeometry geometry = quote.getRouteGeometry();
        return new RouteResponse(quote.getPublicId(), bookingPublicId,
                geometry == null ? Availability.UNAVAILABLE : Availability.AVAILABLE,
                geometry == null ? null : "GEOJSON_LINESTRING", geometry,
                quote.getRoutingProvider(), geometry == null ? null : quote.getIssuedAt(),
                geometry == null ? "ROUTE_GEOMETRY_NOT_CAPTURED" : null);
    }
}
