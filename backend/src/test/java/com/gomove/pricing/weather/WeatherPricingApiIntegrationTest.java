package com.gomove.pricing.weather;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.auth.domain.UserRole;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.booking.domain.Booking;
import com.gomove.booking.domain.BookingRepository;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.Quote;
import com.gomove.pricing.domain.QuoteRepository;
import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.routing.RoutingService;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** API-level integration through Spring Security, JWT, JPA, Flyway and isolated PostGIS Testcontainers. */
@AutoConfigureMockMvc
class WeatherPricingApiIntegrationTest extends BaseIntegrationTest {
    private static final String QUOTES = "/api/v1/quotes";
    private static final String BOOKINGS = "/api/v1/bookings";
    private static final String BODY = """
            {"pickupLatitude":21.0287,"pickupLongitude":105.8524,
             "dropoffLatitude":21.0245,"dropoffLongitude":105.8576,"vehicleType":"MOTORBIKE"}
            """;
    private static final Instant T0 = Instant.parse("2026-11-12T04:00:00Z");
    private static final Instant T1 = T0.plusSeconds(17);

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired UserRepository users;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired JwtTokenProvider jwt;
    @Autowired WeatherPricingProperties properties;
    @MockitoBean RoutingService routing;
    @MockitoBean WeatherProvider provider;
    @MockitoBean Clock clock;
    private final AtomicReference<Instant> now = new AtomicReference<>(T0);

    @BeforeEach
    void setUp() {
        resetPolicy();
        now.set(T0);
        when(clock.instant()).thenAnswer(invocation -> now.get());
        when(routing.calculateRoute(any(GeoCoordinate.class), any(GeoCoordinate.class)))
                .thenAnswer(invocation -> {
                    assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
                    return new RouteEstimate(new BigDecimal("1000.111"), new BigDecimal("60"), "TEST_ROUTER");
                });
        clearInvocations(provider);
    }

    @AfterEach
    void resetConfiguration() {
        resetPolicy();
    }

    @Test
    void disabledWeatherPreservesM1FareAndDoesNotCallProvider() throws Exception {
        User customer = user();
        JsonNode quote = createQuote(customer, BODY);

        assertThat(quote.path("finalFare").decimalValue()).isEqualByComparingTo("16500.00");
        Quote saved = quote(quote, customer);
        assertThat(saved.getPricingSnapshot()).containsEntry("weatherReason", "FEATURE_DISABLED")
                .containsEntry("weatherMultiplier", "1.0000");
        verifyNoInteractions(provider);
    }

    @Test
    void enabledRainIsEvaluatedAtTheSharedPricingTimestampAndQuoteTtlStartsAfterIt() throws Exception {
        properties.setEnabled(true);
        when(provider.currentRain(any())).thenAnswer(invocation -> {
            // Simulate a provider call that completes later without changing the selected policy time.
            now.set(T1);
            return WeatherProvider.Observation.available(T0.minusSeconds(300), new BigDecimal("0.2"), 900, "mm");
        });
        User customer = user();

        JsonNode response = createQuote(customer, BODY);
        Quote saved = quote(response, customer);

        assertThat(response.path("surgeMultiplier").decimalValue()).isEqualByComparingTo("1.1000");
        assertThat(response.path("finalFare").decimalValue()).isEqualByComparingTo("18151.00");
        assertThat(saved.getPricingSnapshot()).containsEntry("weatherPricingPolicyVersion", "WEATHER_V1")
                .containsEntry("weatherProvider", "OPEN_METEO")
                .containsEntry("weatherEvaluationTimestamp", T0.toString())
                .containsEntry("weatherObservationTimestamp", T0.minusSeconds(300).toString())
                .containsEntry("weatherDataStatus", "AVAILABLE")
                .containsEntry("weatherRainMm", "0.2")
                .containsEntry("weatherRainUnit", "mm")
                .containsEntry("weatherReason", "RAIN")
                .containsEntry("weatherMultiplier", "1.1000")
                .containsEntry("requestedWeatherMultiplier", "1.1000")
                .containsEntry("weatherPolicyApplied", "true")
                .containsEntry("weatherApplied", "true")
                .containsEntry("actualMultiplierUplift", "0.1000")
                .containsEntry("weatherUpliftStatus", "FULLY_APPLIED")
                .containsEntry("actualWeatherFareDifferenceVnd", "1651.00")
                .containsEntry("weatherNoRainBelowMm", "0.2")
                .containsEntry("weatherHeavyRainFromMm", "2.0")
                .containsEntry("weatherDataAttribution", "Weather data by Open-Meteo.com")
                .containsEntry("weatherDataLicense", "CC BY 4.0");
        assertThat(saved.getIssuedAt()).isEqualTo(T1);
        assertThat(saved.getExpiresAt()).isEqualTo(T1.plusSeconds(60));
        assertThat(saved.isUsableAt(T1.plusSeconds(59))).isTrue();
        assertThat(saved.isUsableAt(T1.plusSeconds(60))).isFalse();
        verify(provider, times(1)).currentRain(any());
    }

    @Test
    void providerFailureUsesIdentityMultiplierAndIsNotReportedAsNoRain() throws Exception {
        properties.setEnabled(true);
        when(provider.currentRain(any())).thenReturn(WeatherProvider.Observation.unavailable());
        User customer = user();

        JsonNode response = createQuote(customer, BODY);
        Quote saved = quote(response, customer);

        assertThat(response.path("finalFare").decimalValue()).isEqualByComparingTo("16500.00");
        assertThat(saved.getPricingSnapshot()).containsEntry("weatherReason", "PROVIDER_UNAVAILABLE")
                .containsEntry("weatherDataStatus", "PROVIDER_UNAVAILABLE")
                .containsEntry("weatherMultiplier", "1.0000")
                .containsEntry("requestedWeatherMultiplier", "1.0000")
                .containsEntry("weatherPolicyApplied", "false")
                .containsEntry("weatherApplied", "false")
                .containsEntry("actualMultiplierUplift", "0.0000")
                .containsEntry("weatherUpliftStatus", "NO_UPLIFT_REQUESTED")
                .containsEntry("actualWeatherFareDifferenceVnd", "0.00");
    }

    @Test
    void fullySuppressedWeatherSnapshotPersistsOnQuoteAndBooking() throws Exception {
        properties.setEnabled(true);
        properties.setMaximumCombinedMultiplier(new BigDecimal("1.0000"));
        when(provider.currentRain(any())).thenReturn(WeatherProvider.Observation.available(T0,
                new BigDecimal("2.0"), 900, "mm"));
        User customer = user();
        JsonNode quoteResponse = createQuote(customer, BODY);
        Quote quote = quote(quoteResponse, customer);
        var originalSnapshot = quote.getPricingSnapshot();

        assertThat(quote.getFinalFare()).isEqualByComparingTo("16500.00");
        assertThat(originalSnapshot).containsEntry("weatherRainMm", "2.0")
                .containsEntry("requestedWeatherMultiplier", "1.1500")
                .containsEntry("weatherMultiplier", "1.1500")
                .containsEntry("weatherPolicyApplied", "true")
                .containsEntry("weatherApplied", "false")
                .containsEntry("actualMultiplierUplift", "0.0000")
                .containsEntry("weatherUpliftStatus", "FULLY_SUPPRESSED_BY_CAP")
                .containsEntry("actualWeatherFareDifferenceVnd", "0.00")
                .containsEntry("totalSurgeCapApplied", "true");

        String request = "{\"quotePublicId\":\"" + quote.getPublicId() + "\"}";
        String created = mvc.perform(post(BOOKINGS).header("Authorization", bearer(customer))
                        .header("Idempotency-Key", UUID.randomUUID().toString())
                        .contentType(MediaType.APPLICATION_JSON).content(request))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        UUID bookingId = UUID.fromString(mapper.readTree(created).path("data").path("bookingPublicId").asText());
        Booking booking = bookings.findOwned(bookingId, customer.getPublicId()).orElseThrow();

        assertThat(booking.getFinalFare()).isEqualByComparingTo("16500.00");
        assertThat(booking.getPricingSnapshot()).isEqualTo(originalSnapshot);
    }

    @Test
    void quoteToBookingKeepsOriginalWeatherPriceAndSnapshotAfterPolicyChangeAndReplaysIdempotently() throws Exception {
        properties.setEnabled(true);
        when(provider.currentRain(any())).thenReturn(WeatherProvider.Observation.available(T0,
                new BigDecimal("0.2"), 900, "mm"));
        User customer = user();
        JsonNode quoteResponse = createQuote(customer, BODY);
        Quote originalQuote = quote(quoteResponse, customer);
        var originalSnapshot = originalQuote.getPricingSnapshot();
        properties.setRainMultiplier(new BigDecimal("1.1500"));
        properties.setPolicyVersion("WEATHER_V2");

        String key = UUID.randomUUID().toString();
        String request = "{\"quotePublicId\":\"" + originalQuote.getPublicId() + "\"}";
        String created = mvc.perform(post(BOOKINGS).header("Authorization", bearer(customer))
                        .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON).content(request))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        JsonNode bookingResponse = mapper.readTree(created).path("data");
        UUID bookingId = UUID.fromString(bookingResponse.path("bookingPublicId").asText());
        Booking booking = bookings.findOwned(bookingId, customer.getPublicId()).orElseThrow();
        assertThat(booking.getFinalFare()).isEqualByComparingTo("18151.00");
        assertThat(booking.getPricingSnapshot()).isEqualTo(originalSnapshot);
        assertThat(booking.getPricingSnapshot()).containsEntry("weatherMultiplier", "1.1000")
                .containsEntry("weatherPricingPolicyVersion", "WEATHER_V1");

        mvc.perform(get(BOOKINGS + "/" + bookingId).header("Authorization", bearer(customer)))
                .andExpect(status().isOk())
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath(
                        "$.data.finalFare").value(18151.00));
        String replay = mvc.perform(post(BOOKINGS).header("Authorization", bearer(customer))
                        .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON).content(request))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        assertThat(mapper.readTree(replay).path("data").path("bookingPublicId").asText()).isEqualTo(bookingId.toString());
        assertThat(bookings.countByQuoteId(originalQuote.getId())).isEqualTo(1);
        assertThat(quotes.findById(originalQuote.getId()).orElseThrow().getPricingSnapshot()).isEqualTo(originalSnapshot);
    }

    @Test
    void clientCannotInjectWeatherMultiplierOrPricingTimestamp() throws Exception {
        properties.setEnabled(true);
        User customer = user();
        String tampered = BODY.replace("\"vehicleType\":\"MOTORBIKE\"",
                "\"vehicleType\":\"MOTORBIKE\",\"weatherMultiplier\":99,"
                        + "\"rainMm\":500,\"pricingTimestamp\":\"2030-01-01T00:00:00Z\"");
        mvc.perform(post(QUOTES).header("Authorization", bearer(customer))
                        .contentType(MediaType.APPLICATION_JSON).content(tampered))
                .andExpect(status().isBadRequest());
        verifyNoInteractions(provider);
    }

    private JsonNode createQuote(User customer, String body) throws Exception {
        String response = mvc.perform(post(QUOTES).header("Authorization", bearer(customer))
                        .contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        return mapper.readTree(response).path("data");
    }

    private Quote quote(JsonNode response, User customer) {
        return quotes.findByPublicIdAndCustomerPublicId(UUID.fromString(response.path("quotePublicId").asText()),
                customer.getPublicId()).orElseThrow();
    }

    private User user() {
        String unique = UUID.randomUUID().toString().substring(0, 8);
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "weather-" + unique + "@example.test", "hash", "Weather Test");
        user.setRole(UserRole.CUSTOMER);
        return users.saveAndFlush(user);
    }

    private String bearer(User user) {
        return "Bearer " + jwt.createAccessToken(user);
    }

    private void resetPolicy() {
        properties.setEnabled(false);
        properties.setPolicyVersion("WEATHER_V1");
        properties.setNoRainBelowMm(new BigDecimal("0.2"));
        properties.setHeavyRainFromMm(new BigDecimal("2.0"));
        properties.setRainMultiplier(new BigDecimal("1.10"));
        properties.setHeavyRainMultiplier(new BigDecimal("1.15"));
        properties.setMaximumCombinedMultiplier(new BigDecimal("1.50"));
    }
}
