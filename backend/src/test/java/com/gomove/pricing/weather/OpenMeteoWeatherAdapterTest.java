package com.gomove.pricing.weather;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.pricing.domain.GeoCoordinate;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withException;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;
import static org.springframework.http.HttpMethod.GET;

class OpenMeteoWeatherAdapterTest {
    private static final Instant NOW = Instant.parse("2026-11-12T04:00:00Z");
    private MockRestServiceServer server;
    private MutableClock clock;
    private WeatherPricingProperties properties;
    private OpenMeteoWeatherAdapter adapter;

    @BeforeEach
    void setUp() {
        RestClient.Builder builder = RestClient.builder();
        server = MockRestServiceServer.bindTo(builder).build();
        properties = new WeatherPricingProperties();
        properties.setBaseUrl("https://api.open-meteo.com");
        clock = new MutableClock(NOW);
        adapter = new OpenMeteoWeatherAdapter(builder.build(), properties, new ObjectMapper(), clock);
    }

    @Test
    void requestsUtcRainInMmAndParsesTimestampIntervalAndDecimalValue() {
        server.expect(request -> {
            assertThat(request.getMethod()).isEqualTo(GET);
            assertThat(request.getURI().getPath()).isEqualTo("/v1/forecast");
            assertThat(request.getURI().getQuery()).isEqualTo(
                    "latitude=21.03&longitude=105.85&current=rain&precipitation_unit=mm&timeformat=unixtime&timezone=UTC");
            assertThat(request.getHeaders().getFirst("Authorization")).isNull();
        }).andRespond(withSuccess(valid("0.25", 900, "mm", "seconds", NOW), MediaType.APPLICATION_JSON));

        WeatherProvider.Observation observation = adapter.currentRain(pickup());

        assertThat(observation.status()).isEqualTo(WeatherProvider.Status.AVAILABLE);
        assertThat(observation.rainMm()).isEqualByComparingTo("0.25");
        assertThat(observation.observedAt()).isEqualTo(NOW);
        assertThat(observation.intervalSeconds()).isEqualTo(900);
        assertThat(observation.unit()).isEqualTo("mm");
        server.verify();
    }

    @Test
    void acceptsUtcTimezoneAliasWhenOffsetIsZero() {
        server.expect(request -> assertThat(request.getURI().getPath()).isEqualTo("/v1/forecast"))
                .andRespond(withSuccess(valid("0.0", 900, "mm", "seconds", NOW)
                        .replace("\"GMT\"", "\"UTC\""), MediaType.APPLICATION_JSON));

        assertThat(adapter.currentRain(pickup()).status()).isEqualTo(WeatherProvider.Status.AVAILABLE);
        server.verify();
    }

    @Test
    void networkTimeout429AndServerErrorAreOptionalProviderFailures() {
        server.expect(request -> assertThat(request.getURI().getPath()).isEqualTo("/v1/forecast"))
                .andRespond(withException(new java.net.SocketTimeoutException("synthetic timeout")));
        server.expect(request -> assertThat(request.getURI().getPath()).isEqualTo("/v1/forecast"))
                .andRespond(withStatus(HttpStatus.TOO_MANY_REQUESTS));
        server.expect(request -> assertThat(request.getURI().getPath()).isEqualTo("/v1/forecast"))
                .andRespond(withStatus(HttpStatus.BAD_GATEWAY));
        assertThat(adapter.currentRain(pickup()).status()).isEqualTo(WeatherProvider.Status.PROVIDER_UNAVAILABLE);
        assertThat(adapter.currentRain(new GeoCoordinate(new BigDecimal("21.04"), new BigDecimal("105.85"))).status())
                .isEqualTo(WeatherProvider.Status.PROVIDER_UNAVAILABLE);
        assertThat(adapter.currentRain(new GeoCoordinate(new BigDecimal("21.05"), new BigDecimal("105.85"))).status())
                .isEqualTo(WeatherProvider.Status.PROVIDER_UNAVAILABLE);
        server.verify();
    }

    @Test
    void malformedMissingUnsupportedNegativeAndOversizedDataAreRejected() {
        String[] invalidBodies = {
                "{invalid-json",
                "{\"timezone\":\"UTC\",\"current\":{},\"current_units\":{}}",
                valid("1.0", 3600, "mm", "seconds", NOW),
                valid("1.0", 900, "inch", "seconds", NOW),
                valid("-0.1", 900, "mm", "seconds", NOW),
                valid("1.0", 900, "mm", "seconds", NOW).replace("\"GMT\"", "\"Europe/Berlin\"")
                        .replace("\"utc_offset_seconds\":0", "\"utc_offset_seconds\":3600")
        };
        for (int index = 0; index < invalidBodies.length; index++) {
            server.expect(request -> assertThat(request.getURI().getPath()).isEqualTo("/v1/forecast"))
                    .andRespond(withSuccess(invalidBodies[index], MediaType.APPLICATION_JSON));
        }
        server.expect(request -> assertThat(request.getURI().getPath()).isEqualTo("/v1/forecast"))
                .andRespond(withSuccess(" ".repeat(9000), MediaType.APPLICATION_JSON));
        for (int index = 0; index < invalidBodies.length; index++) {
            WeatherProvider.Observation observation = adapter.currentRain(new GeoCoordinate(
                    BigDecimal.valueOf(22 + index), new BigDecimal("106.00")));
            assertThat(observation.status()).isEqualTo(WeatherProvider.Status.INVALID_DATA);
        }
        assertThat(adapter.currentRain(new GeoCoordinate(new BigDecimal("30"), new BigDecimal("106"))).status())
                .isEqualTo(WeatherProvider.Status.INVALID_DATA);
        server.verify();
    }

    @Test
    void successfulResultsAreCachedOnlyForConfiguredTtl() {
        server.expect(request -> assertThat(request.getURI().getPath()).isEqualTo("/v1/forecast"))
                .andRespond(withSuccess(valid("0.5", 900, "mm", "seconds", NOW), MediaType.APPLICATION_JSON));
        server.expect(request -> assertThat(request.getURI().getPath()).isEqualTo("/v1/forecast"))
                .andRespond(withSuccess(valid("0.8", 900, "mm", "seconds", NOW.plusSeconds(120)),
                        MediaType.APPLICATION_JSON));
        assertThat(adapter.currentRain(pickup()).rainMm()).isEqualByComparingTo("0.5");
        assertThat(adapter.currentRain(pickup()).rainMm()).isEqualByComparingTo("0.5");

        clock.set(NOW.plusSeconds(120));
        assertThat(adapter.currentRain(pickup()).rainMm()).isEqualByComparingTo("0.8");
        server.verify();
    }

    @Test
    void cacheRemainsBoundedAndEvictsLeastRecentlyUsedEntry() {
        properties.setCacheCapacity(2);
        RestClient.Builder builder = RestClient.builder();
        server = MockRestServiceServer.bindTo(builder).build();
        adapter = new OpenMeteoWeatherAdapter(builder.build(), properties, new ObjectMapper(), clock);
        for (int index = 0; index < 4; index++) {
            server.expect(request -> assertThat(request.getURI().getPath()).isEqualTo("/v1/forecast"))
                    .andRespond(withSuccess(valid("0.1", 900, "mm", "seconds", NOW), MediaType.APPLICATION_JSON));
        }
        adapter.currentRain(new GeoCoordinate(new BigDecimal("21"), new BigDecimal("105")));
        adapter.currentRain(new GeoCoordinate(new BigDecimal("22"), new BigDecimal("105")));
        adapter.currentRain(new GeoCoordinate(new BigDecimal("23"), new BigDecimal("105")));
        assertThat(adapter.cachedEntryCount()).isEqualTo(2);
        adapter.currentRain(new GeoCoordinate(new BigDecimal("21"), new BigDecimal("105")));
        assertThat(adapter.cachedEntryCount()).isEqualTo(2);
        server.verify();
    }

    @Test
    void configurationRejectsRedirectableOrUntrustedProviderEndpoints() {
        for (String value : new String[]{"http://api.open-meteo.com", "https://example.test",
                "https://api.open-meteo.com@attacker.test", "https://api.open-meteo.com/v1?next=evil"}) {
            org.assertj.core.api.Assertions.assertThatThrownBy(() -> WeatherConfiguration.validateEndpoint(value))
                    .isInstanceOf(IllegalArgumentException.class)
                    .hasMessageContaining("fixed HTTPS Open-Meteo endpoint");
        }
        WeatherConfiguration.validateEndpoint("https://api.open-meteo.com");
    }

    private String valid(String rain, int interval, String rainUnit, String intervalUnit, Instant time) {
        return "{\"timezone\":\"GMT\",\"utc_offset_seconds\":0,\"current\":{\"time\":" + time.getEpochSecond()
                + ",\"interval\":" + interval + ",\"rain\":" + rain + "},"
                + "\"current_units\":{\"interval\":\"" + intervalUnit + "\",\"rain\":\"" + rainUnit + "\"}}";
    }

    private GeoCoordinate pickup() {
        return new GeoCoordinate(new BigDecimal("21.0288"), new BigDecimal("105.8525"));
    }

    private static class MutableClock extends Clock {
        private final AtomicReference<Instant> instant;
        MutableClock(Instant instant) { this.instant = new AtomicReference<>(instant); }
        void set(Instant value) { instant.set(value); }
        @Override public ZoneId getZone() { return ZoneOffset.UTC; }
        @Override public Clock withZone(ZoneId zone) { return Clock.fixed(instant.get(), zone); }
        @Override public Instant instant() { return instant.get(); }
    }
}
