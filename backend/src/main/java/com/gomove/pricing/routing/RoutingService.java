package com.gomove.pricing.routing;

import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.RouteEstimate;

public interface RoutingService {
    RouteEstimate calculateRoute(GeoCoordinate pickup, GeoCoordinate dropoff);
}
