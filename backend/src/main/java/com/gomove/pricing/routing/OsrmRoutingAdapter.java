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
        try {
            URI uri = routeUri(pickup, dropoff);
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
                RouteGeometry geometry = geometry(routes.get(0).path("geometry"), pickup, dropoff);
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

    private URI routeUri(GeoCoordinate pickup, GeoCoordinate dropoff) {
        try {
            return URI.create(properties.getBaseUrl().replaceAll("/+$", "")
                    + "/route/v1/driving/"
                    + pickup.longitude().toPlainString() + "," + pickup.latitude().toPlainString()
                    + ";" + dropoff.longitude().toPlainString() + "," + dropoff.latitude().toPlainString()
                    + "?overview=full&geometries=geojson");
        } catch (IllegalArgumentException | NullPointerException ex) {
            throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE,
                    "ROUTING_UNAVAILABLE", "Road routing is temporarily unavailable");
        }
    }

    private BigDecimal decimal(JsonNode node) {
        if (!node.isNumber()) throw invalidResponse();
        return node.decimalValue();
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
