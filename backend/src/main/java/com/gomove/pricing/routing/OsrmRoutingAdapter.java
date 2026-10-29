package com.gomove.pricing.routing;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.common.exception.DomainException;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.domain.RouteGeometry;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;
import org.springframework.web.client.RestClientResponseException;

import java.math.BigDecimal;
import java.net.URI;
import java.util.ArrayList;
import java.util.List;

@Component
public class OsrmRoutingAdapter implements RoutingService {
    private static final int MAX_RESPONSE_CHARACTERS = 1_048_576;
    private final RestClient client;
    private final OsrmProperties properties;
    private final ObjectMapper mapper;

    public OsrmRoutingAdapter(
            @Qualifier("osrmRestClient") RestClient client,
            OsrmProperties properties,
            ObjectMapper mapper
    ) {
        this.client = client;
        this.properties = properties;
        this.mapper = mapper;
    }

    @Override
    public RouteEstimate calculateRoute(GeoCoordinate pickup, GeoCoordinate dropoff) {
        return requestRoute(pickup, dropoff, true);
    }

    @Override
    public RouteEstimate calculateTravelMetrics(GeoCoordinate origin, GeoCoordinate destination) {
        return requestRoute(origin, destination, false);
    }

    private RouteEstimate requestRoute(GeoCoordinate pickup, GeoCoordinate dropoff, boolean includeGeometry) {
        try {
            URI uri = routeUri(pickup, dropoff, includeGeometry);
            String body = client.get().uri(uri).header("User-Agent", "GoMove-Academic/1.0")
                    .retrieve().body(String.class);
            if (body == null || body.length() > MAX_RESPONSE_CHARACTERS) throw invalidResponse();
            JsonNode response = mapper.readTree(body);
            if (response == null || !response.path("code").isTextual()) {
                throw invalidResponse();
            }
            if ("NoRoute".equals(response.path("code").asText())) {
                throw new DomainException(HttpStatus.UNPROCESSABLE_ENTITY, "ROUTE_NOT_FOUND", "No road route is available");
            }
            if (!"Ok".equals(response.path("code").asText())) {
                throw invalidResponse();
            }
            JsonNode routes = response.path("routes");
            if (!routes.isArray() || routes.isEmpty()) {
                throw new DomainException(HttpStatus.UNPROCESSABLE_ENTITY, "ROUTE_NOT_FOUND", "No road route is available");
            }
            BigDecimal distance = decimal(routes.get(0).path("distance"));
            BigDecimal duration = decimal(routes.get(0).path("duration"));
            try {
                RouteGeometry geometry = includeGeometry
                        ? geometry(routes.get(0).path("geometry"), pickup, dropoff) : null;
                if (!includeGeometry) validateEtaWaypoints(response.path("waypoints"), pickup, dropoff);
                return new RouteEstimate(distance, duration, "OSRM", geometry);
            } catch (IllegalArgumentException ex) {
                throw invalidResponse();
            }
        } catch (DomainException ex) {
            throw ex;
        } catch (RestClientResponseException ex) {
            if (ex.getStatusCode().value() == 400) {
                try {
                    JsonNode error = mapper.readTree(ex.getResponseBodyAsString());
                    if (error != null && "NoRoute".equals(error.path("code").asText())) {
                        throw new DomainException(HttpStatus.UNPROCESSABLE_ENTITY,
                                "ROUTE_NOT_FOUND", "No road route is available");
                    }
                } catch (JsonProcessingException ignored) {
                    // An invalid provider error body is reported as a bad gateway below.
                }
                throw invalidResponse();
            }
            throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE,
                    "ROUTING_UNAVAILABLE", "Road routing is temporarily unavailable");
        } catch (RestClientException ex) {
            throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "ROUTING_UNAVAILABLE", "Road routing is temporarily unavailable");
        } catch (JsonProcessingException | IllegalArgumentException ex) {
            throw invalidResponse();
        }
    }

    private URI routeUri(GeoCoordinate pickup, GeoCoordinate dropoff, boolean includeGeometry) {
        try {
            return URI.create(properties.getBaseUrl().replaceAll("/+$", "")
                    + "/route/v1/driving/"
                    + pickup.longitude().toPlainString() + "," + pickup.latitude().toPlainString()
                    + ";" + dropoff.longitude().toPlainString() + "," + dropoff.latitude().toPlainString()
                    + (includeGeometry ? "?overview=full&geometries=geojson" : "?overview=false"));
        } catch (IllegalArgumentException | NullPointerException ex) {
            throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE,
                    "ROUTING_UNAVAILABLE", "Road routing is temporarily unavailable");
        }
    }

    private BigDecimal decimal(JsonNode node) {
        if (!node.isNumber()) throw invalidResponse();
        return node.decimalValue();
    }

    private void validateEtaWaypoints(JsonNode waypoints, GeoCoordinate origin, GeoCoordinate destination) {
        if (!waypoints.isArray() || waypoints.size() != 2) throw invalidResponse();
        List<List<BigDecimal>> snapped = new ArrayList<>(2);
        for (JsonNode waypoint : waypoints) {
            BigDecimal snapDistance = decimal(waypoint.path("distance"));
            if (snapDistance.signum() < 0 || snapDistance.compareTo(BigDecimal.valueOf(200)) > 0) {
                throw invalidResponse();
            }
            JsonNode location = waypoint.path("location");
            if (!location.isArray() || location.size() != 2) throw invalidResponse();
            snapped.add(List.of(decimal(location.get(0)), decimal(location.get(1))));
        }
        new RouteGeometry("LineString", snapped).validateEndpoints(origin, destination);
        // Verify the returned coordinates as well as OSRM's reported snap distances.
        // A distant road snap would make a seemingly precise live ETA misleading.
        if (snapDistanceMeters(snapped.get(0), origin) > 200
                || snapDistanceMeters(snapped.get(1), destination) > 200) throw invalidResponse();
    }

    private double snapDistanceMeters(List<BigDecimal> snapped, GeoCoordinate requested) {
        double lat1 = Math.toRadians(snapped.get(1).doubleValue());
        double lat2 = Math.toRadians(requested.latitude().doubleValue());
        double dLat = lat2 - lat1;
        double dLon = Math.toRadians(requested.longitude().doubleValue()
                - snapped.get(0).doubleValue());
        double a = Math.pow(Math.sin(dLat / 2), 2)
                + Math.cos(lat1) * Math.cos(lat2) * Math.pow(Math.sin(dLon / 2), 2);
        return 2 * 6_371_000 * Math.asin(Math.min(1, Math.sqrt(a)));
    }

    private RouteGeometry geometry(JsonNode node, GeoCoordinate pickup, GeoCoordinate dropoff)
            throws JsonProcessingException {
        if (!node.isObject() || !"LineString".equals(node.path("type").asText())
                || !node.path("coordinates").isArray()
                || node.path("coordinates").size() < 2
                || node.path("coordinates").size() > RouteGeometry.MAX_VERTICES
                || mapper.writeValueAsBytes(node).length > RouteGeometry.MAX_JSON_BYTES) {
            throw invalidResponse();
        }
        List<List<BigDecimal>> coordinates = new ArrayList<>(node.path("coordinates").size());
        for (JsonNode pair : node.path("coordinates")) {
            if (!pair.isArray() || pair.size() != 2) throw invalidResponse();
            coordinates.add(List.of(decimal(pair.get(0)), decimal(pair.get(1))));
        }
        RouteGeometry geometry = new RouteGeometry("LineString", coordinates);
        geometry.validateEndpoints(pickup, dropoff);
        return geometry;
    }

    private DomainException invalidResponse() {
        return new DomainException(HttpStatus.BAD_GATEWAY, "ROUTING_INVALID_RESPONSE", "Road routing returned an invalid response");
    }
}
