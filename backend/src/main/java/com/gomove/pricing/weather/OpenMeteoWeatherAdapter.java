package com.gomove.pricing.weather;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.pricing.domain.GeoCoordinate;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.http.MediaType;
import org.springframework.http.client.ClientHttpResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;
import org.springframework.web.util.UriComponentsBuilder;

import java.io.IOException;
import java.math.BigDecimal;
import java.net.URI;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;

@Component
public class OpenMeteoWeatherAdapter implements WeatherProvider {
    private static final int MAX_RESPONSE_BYTES = 8_192;
    private final RestClient client;
    private final WeatherPricingProperties properties;
    private final ObjectMapper mapper;
    private final Clock clock;
    private final Map<String, CacheEntry> cache = new LinkedHashMap<>(16, 0.75f, true);

    public OpenMeteoWeatherAdapter(@Qualifier("openMeteoWeatherRestClient") RestClient client,
                                   WeatherPricingProperties properties, ObjectMapper mapper, Clock clock) {
        this.client = client;
        this.properties = properties;
        this.mapper = mapper;
        this.clock = clock;
        validateCacheConfiguration(properties);
    }

    @Override
    public Observation currentRain(GeoCoordinate pickup) {
        if (pickup == null) return Observation.invalid();
        RoundedCoordinate rounded = round(pickup);
        String key = cacheKey(rounded);
        Instant now = clock.instant();
        Observation cached = cached(key, now);
        if (cached != null) return cached;

        Observation fetched;
        try {
            fetched = client.get().uri(requestUri(rounded))
                    .header("User-Agent", "GoMove-Academic/1.0")
                    .accept(MediaType.APPLICATION_JSON)
                    .exchange((request, response) -> parse(response));
        } catch (RestClientException ex) {
            fetched = Observation.unavailable();
        }
        put(key, fetched, clock.instant());
        return fetched;
    }

    private Observation parse(ClientHttpResponse response) throws IOException {
        int status = response.getStatusCode().value();
        if (status == 429 || status == 408 || response.getStatusCode().is5xxServerError()) {
            return Observation.unavailable();
        }
        if (!response.getStatusCode().is2xxSuccessful() || response.getBody() == null) {
            return Observation.invalid();
        }
        byte[] body = response.getBody().readNBytes(MAX_RESPONSE_BYTES + 1);
        if (body.length > MAX_RESPONSE_BYTES) return Observation.invalid();
        try {
            JsonNode payload = mapper.readTree(body);
            JsonNode current = payload == null ? null : payload.path("current");
            JsonNode units = payload == null ? null : payload.path("current_units");
            JsonNode utcOffset = payload == null ? null : payload.path("utc_offset_seconds");
            String timezone = payload == null ? "" : payload.path("timezone").asText();
            if (payload == null || !("UTC".equals(timezone) || "GMT".equals(timezone))
                    || !utcOffset.isIntegralNumber() || !utcOffset.canConvertToInt() || utcOffset.intValue() != 0
                    || current == null || !current.isObject() || !units.isObject()) return Observation.invalid();
            JsonNode rain = current.path("rain");
            JsonNode time = current.path("time");
            JsonNode interval = current.path("interval");
            if (!rain.isNumber() || !time.isIntegralNumber() || !time.canConvertToLong()
                    || !interval.canConvertToInt() || !interval.isIntegralNumber()
                    || interval.intValue() != properties.getExpectedIntervalSeconds()
                    || !"mm".equals(units.path("rain").asText())
                    || !"seconds".equals(units.path("interval").asText())) return Observation.invalid();
            BigDecimal amount = rain.decimalValue();
            if (amount.signum() < 0) return Observation.invalid();
            Instant observedAt = Instant.ofEpochSecond(time.longValue());
            return Observation.available(observedAt, amount, interval.intValue(), "mm");
        } catch (JsonProcessingException | ArithmeticException | java.time.DateTimeException ex) {
            return Observation.invalid();
        }
    }

    private URI requestUri(RoundedCoordinate coordinate) {
        return UriComponentsBuilder.fromUriString(properties.getBaseUrl())
                .path("/v1/forecast")
                .queryParam("latitude", coordinate.latitude().toPlainString())
                .queryParam("longitude", coordinate.longitude().toPlainString())
                .queryParam("current", "rain")
                .queryParam("precipitation_unit", "mm")
                .queryParam("timeformat", "unixtime")
                .queryParam("timezone", "UTC")
                .build().encode().toUri();
    }

    private RoundedCoordinate round(GeoCoordinate coordinate) {
        int decimals = properties.getCacheGridDecimals();
        return new RoundedCoordinate(coordinate.latitude().setScale(decimals, java.math.RoundingMode.HALF_UP),
                coordinate.longitude().setScale(decimals, java.math.RoundingMode.HALF_UP));
    }

    private String cacheKey(RoundedCoordinate coordinate) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest((coordinate.latitude().toPlainString() + "," + coordinate.longitude().toPlainString())
                            .getBytes(java.nio.charset.StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException ex) {
            throw new IllegalStateException("SHA-256 is unavailable", ex);
        }
    }

    private Observation cached(String key, Instant now) {
        synchronized (cache) {
            CacheEntry entry = cache.get(key);
            if (entry == null) return null;
            if (!now.isBefore(entry.expiresAt())) {
                cache.remove(key);
                return null;
            }
            return entry.observation();
        }
    }

    private void put(String key, Observation observation, Instant now) {
        java.time.Duration duration = observation.status() == Status.AVAILABLE
                ? properties.getSuccessfulCacheTtl() : properties.getFailureCacheTtl();
        synchronized (cache) {
            for (Iterator<Map.Entry<String, CacheEntry>> iterator = cache.entrySet().iterator(); iterator.hasNext();) {
                if (!now.isBefore(iterator.next().getValue().expiresAt())) iterator.remove();
            }
            cache.put(key, new CacheEntry(observation, now.plus(duration)));
            while (cache.size() > properties.getCacheCapacity()) {
                cache.remove(cache.keySet().iterator().next());
            }
        }
    }

    private void validateCacheConfiguration(WeatherPricingProperties config) {
        if (config.getCacheCapacity() <= 0 || config.getCacheGridDecimals() < 0
                || config.getCacheGridDecimals() > 6 || !positive(config.getSuccessfulCacheTtl())
                || !positive(config.getFailureCacheTtl())) {
            throw new IllegalArgumentException("Weather cache capacity, grid and TTL settings must be bounded and positive");
        }
    }

    private boolean positive(java.time.Duration duration) {
        return duration != null && !duration.isZero() && !duration.isNegative();
    }

    int cachedEntryCount() {
        synchronized (cache) { return cache.size(); }
    }

    private record RoundedCoordinate(BigDecimal latitude, BigDecimal longitude) { }
    private record CacheEntry(Observation observation, Instant expiresAt) { }
}
