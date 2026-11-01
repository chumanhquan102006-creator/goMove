package com.gomove.geocoding.infrastructure;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.common.exception.DomainException;
import com.gomove.geocoding.api.PlaceResponse;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.client.ClientHttpResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;
import org.springframework.web.util.UriComponentsBuilder;

import java.io.IOException;
import java.net.URI;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;

@Component
public class PhotonGeocoder {
    private static final int SEARCH_LIMIT = 5;
    private static final int MAX_RESPONSE_BYTES = 128_000;
    private static final double REVERSE_RADIUS_KM = 0.2;
    private final RestClient client;
    private final GeocodingProperties properties;
    private final ObjectMapper mapper;

    public PhotonGeocoder(@Qualifier("photonRestClient") RestClient client,
                         GeocodingProperties properties, ObjectMapper mapper) {
        this.client = client;
        this.properties = properties;
        this.mapper = mapper;
    }

    public List<PlaceResponse> search(String query) {
        JsonNode features = features(uri("/api", "q", query, "limit", SEARCH_LIMIT));
        List<PlaceResponse> places = new ArrayList<>(Math.min(features.size(), SEARCH_LIMIT));
        for (JsonNode feature : features) {
            if (places.size() == SEARCH_LIMIT) break;
            PlaceResponse place = place(feature, null, null);
            if (place != null) places.add(place);
        }
        return List.copyOf(places);
    }

    public PlaceResponse reverse(double latitude, double longitude) {
        JsonNode features = features(uri("/reverse", "lat", latitude, "lon", longitude,
                "limit", 1, "radius", REVERSE_RADIUS_KM));
        if (features.isEmpty()) return null;
        PlaceResponse nearest = place(features.get(0), latitude, longitude);
        if (nearest == null) return null;
        // Photon returns a nearby feature centroid; the user's selected point remains exact.
        JsonNode coordinates = features.get(0).path("geometry").path("coordinates");
        if (distanceMeters(latitude, longitude, coordinates.get(1).asDouble(),
                coordinates.get(0).asDouble()) > REVERSE_RADIUS_KM * 1000) return null;
        return nearest;
    }

    private URI uri(String path, Object... parameters) {
        try {
            var builder = UriComponentsBuilder.fromUriString(
                    properties.getBaseUrl().replaceAll("/+$", "")).path(path);
            for (int i = 0; i < parameters.length; i += 2) {
                builder.queryParam(parameters[i].toString(), parameters[i + 1]);
            }
            return builder.build().encode().toUri();
        } catch (IllegalArgumentException | NullPointerException ex) {
            throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE,
                    "GEOCODING_UNAVAILABLE", "Address lookup is temporarily unavailable");
        }
    }

    private JsonNode features(URI uri) {
        try {
            // Construct this request from validated search text or coordinates only. Never copy
            // inbound Authorization, cookies, account IDs or Booking IDs to the provider.
            return client.get().uri(uri).header("User-Agent", "GoMove-Academic/1.0")
                    .accept(MediaType.APPLICATION_JSON).exchange((request, response) -> parse(response));
        } catch (DomainException ex) {
            throw ex;
        } catch (RestClientException ex) {
            throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE,
                    "GEOCODING_UNAVAILABLE", "Address lookup is temporarily unavailable");
        }
    }

    private JsonNode parse(ClientHttpResponse response) throws IOException {
        int status = response.getStatusCode().value();
        if (status == 429) {
            throw new DomainException(HttpStatus.TOO_MANY_REQUESTS,
                    "GEOCODING_RATE_LIMITED", "Address lookup is rate limited");
        }
        if (status == 408 || response.getStatusCode().is5xxServerError()) {
            throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE,
                    "GEOCODING_UNAVAILABLE", "Address lookup is temporarily unavailable");
        }
        if (!response.getStatusCode().is2xxSuccessful() || response.getBody() == null) {
            throw invalidResponse();
        }
        // Read at most one byte beyond the cap. A malicious or misconfigured provider
        // cannot make the HTTP client buffer an unbounded response before validation.
        byte[] body = response.getBody().readNBytes(MAX_RESPONSE_BYTES + 1);
        if (body.length > MAX_RESPONSE_BYTES) throw invalidResponse();
        try {
            JsonNode payload = mapper.readTree(body);
            JsonNode features = payload == null ? null : payload.path("features");
            if (features == null || !features.isArray()) throw invalidResponse();
            return features;
        } catch (JsonProcessingException ex) {
            throw invalidResponse();
        }
    }

    private PlaceResponse place(JsonNode feature, Double selectedLatitude, Double selectedLongitude) {
        if (!feature.isObject()) throw invalidResponse();
        JsonNode geometry = feature.path("geometry");
        JsonNode coordinates = geometry.path("coordinates");
        if (!"Point".equals(geometry.path("type").asText())
                || !coordinates.isArray() || coordinates.size() != 2
                || !coordinates.get(0).isNumber() || !coordinates.get(1).isNumber()) throw invalidResponse();
        double longitude = coordinates.get(0).asDouble();
        double latitude = coordinates.get(1).asDouble();
        if (!Double.isFinite(latitude) || latitude < -90 || latitude > 90
                || !Double.isFinite(longitude) || longitude < -180 || longitude > 180) throw invalidResponse();
        JsonNode details = feature.path("properties");
        if (!details.isObject()) throw invalidResponse();
        String name = field(details, "name");
        String street = field(details, "street");
        String number = field(details, "housenumber");
        String district = field(details, "district");
        String city = field(details, "city");
        String state = field(details, "state");
        LinkedHashSet<String> labelParts = new LinkedHashSet<>();
        add(labelParts, name);
        add(labelParts, street == null ? null : number == null ? street : number + " " + street);
        add(labelParts, district);
        add(labelParts, city);
        add(labelParts, state);
        if (labelParts.isEmpty()) return null;
        return new PlaceResponse(String.join(", ", labelParts), name, street, district, city,
                selectedLatitude == null ? latitude : selectedLatitude,
                selectedLongitude == null ? longitude : selectedLongitude,
                PlaceResponse.OSM_ATTRIBUTION);
    }

    private void add(LinkedHashSet<String> parts, String value) {
        if (value != null) parts.add(value);
    }

    private String field(JsonNode node, String key) {
        JsonNode value = node.path(key);
        if (value.isMissingNode() || value.isNull()) return null;
        if (!value.isTextual() || value.asText().length() > 160) throw invalidResponse();
        String normalized = value.asText().strip();
        return normalized.isEmpty() ? null : normalized;
    }

    private double distanceMeters(double firstLat, double firstLon, double secondLat, double secondLon) {
        double dLat = Math.toRadians(secondLat - firstLat);
        double dLon = Math.toRadians(secondLon - firstLon);
        double lat1 = Math.toRadians(firstLat);
        double lat2 = Math.toRadians(secondLat);
        double a = Math.pow(Math.sin(dLat / 2), 2)
                + Math.cos(lat1) * Math.cos(lat2) * Math.pow(Math.sin(dLon / 2), 2);
        return 2 * 6_371_000 * Math.asin(Math.min(1, Math.sqrt(a)));
    }

    private DomainException invalidResponse() {
        return new DomainException(HttpStatus.BAD_GATEWAY,
                "GEOCODING_INVALID_RESPONSE", "Address provider returned an invalid response");
    }
}
