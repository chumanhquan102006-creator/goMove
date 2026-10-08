package com.gomove.pricing.routing;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.common.exception.DomainException;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.RouteEstimate;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;
import org.springframework.web.client.RestClientResponseException;

import java.math.BigDecimal;
import java.net.URI;

@Component
public class OsrmRoutingAdapter implements RoutingService {
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
                return new RouteEstimate(distance, duration, "OSRM");
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
                    + "?overview=false");
        } catch (IllegalArgumentException | NullPointerException ex) {
            throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE,
                    "ROUTING_UNAVAILABLE", "Road routing is temporarily unavailable");
        }
    }

    private BigDecimal decimal(JsonNode node) {
        if (!node.isNumber()) throw invalidResponse();
        return node.decimalValue();
    }

    private DomainException invalidResponse() {
        return new DomainException(HttpStatus.BAD_GATEWAY, "ROUTING_INVALID_RESPONSE", "Road routing returned an invalid response");
    }
}
