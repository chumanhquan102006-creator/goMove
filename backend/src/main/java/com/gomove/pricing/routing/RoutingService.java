package com.gomove.pricing.routing;

import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.RouteEstimate;

public interface RoutingService {
    RouteEstimate calculateRoute(GeoCoordinate pickup, GeoCoordinate dropoff);

    /** Transient road metrics for journey ETA; never stored in a Quote or used for fare calculation. */
    RouteEstimate calculateTravelMetrics(GeoCoordinate origin, GeoCoordinate destination);
}
