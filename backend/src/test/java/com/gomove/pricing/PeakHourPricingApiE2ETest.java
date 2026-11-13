package com.gomove.pricing;

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
import com.gomove.pricing.engine.FareBreakdown;
import com.gomove.pricing.engine.PeakHourPricingPolicy;
import com.gomove.pricing.engine.PeakHourPricingProperties;
import com.gomove.pricing.engine.PricingEngine;
import com.gomove.pricing.routing.RoutingService;
import com.gomove.pricing.weather.WeatherPricingPolicy;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.http.HttpStatus;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@SpringBootTest(properties = "gomove.pricing.peak-hour.enabled=false")
@AutoConfigureMockMvc
@Import(PeakHourPricingApiE2ETest.TestClockConfiguration.class)
class PeakHourPricingApiE2ETest extends BaseIntegrationTest {
    private static final String QUOTES = "/api/v1/quotes";
    private static final String BOOKINGS = "/api/v1/bookings";
    private static final String QUOTE_BODY = """
            {"pickupLatitude":21.0287,"pickupLongitude":105.8524,
             "dropoffLatitude":21.0245,"dropoffLongitude":105.8576,"vehicleType":"MOTORBIKE"}
            """;
    private static final Instant MONDAY_MORNING = Instant.parse("2026-10-05T01:30:00Z");
    private static final Instant MONDAY_EVENING = Instant.parse("2026-10-05T10:30:00Z");
    private static final Instant MONDAY_AFTER_MORNING = Instant.parse("2026-10-05T02:00:00Z");
    private static final Instant SATURDAY_MORNING = Instant.parse("2026-10-10T01:00:00Z");
    private static final Instant T0_BEFORE_WINDOW_END = Instant.parse("2026-10-05T01:59:45Z");
    private static final Instant T1_AFTER_WINDOW_END = Instant.parse("2026-10-05T02:00:15Z");

    @Autowired MockMvc http;
    @Autowired ObjectMapper mapper;
    @Autowired UserRepository users;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired JwtTokenProvider jwt;
    @Autowired PeakHourPricingProperties peakProperties;
    @Autowired PeakHourPricingPolicy peakPolicy;
    @Autowired MutableTestClock clock;
    @MockitoBean RoutingService routing;
    @MockitoSpyBean PricingEngine pricing;

    @BeforeEach
    void setUp() {
        resetPeakConfiguration();
        clock.set(MONDAY_MORNING);
        when(routing.calculateRoute(any(GeoCoordinate.class), any(GeoCoordinate.class)))
                .thenReturn(new RouteEstimate(new BigDecimal("1000"), new BigDecimal("60"), "E2E_ROUTING_STUB"));
    }

    @AfterEach
    void restoreConfiguration() {
        resetPeakConfiguration();
    }

    @Test
    void e2e01FeatureDisabledAtPeakTimeReturnsNormalFare() {
        assertThat(peakProperties.isEnabled()).isFalse();
        clock.set(MONDAY_MORNING);
        Session customer = user(UserRole.CUSTOMER);

        ResponseEntity<JsonNode> response = createQuote(customer, QUOTE_BODY);

        assertThat(response.getStatusCode().value()).isEqualTo(201);
        JsonNode data = data(response);
        assertThat(data.path("finalFare").decimalValue()).isEqualByComparingTo("16500.00");
        assertThat(data.path("surgeMultiplier").decimalValue()).isEqualByComparingTo("1.0000");
        assertThat(data.path("surgeAmount").decimalValue()).isEqualByComparingTo("0.00");
        Quote quote = quote(data, customer.user());
        assertThat(quote.getPricingSnapshot()).containsEntry("peakHourApplied", "false")
                .containsEntry("peakHourReason", "FEATURE_DISABLED");
    }

    @Test
    void e2e02MondayMorningPeakAddsTwentyPercent() {
        enablePeak();
        clock.set(MONDAY_MORNING);
        Session customer = user(UserRole.CUSTOMER);

        ResponseEntity<JsonNode> response = createQuote(customer, QUOTE_BODY);

        assertThat(response.getStatusCode().value()).isEqualTo(201);
        assertPeakFare(data(response));
        verify(routing).calculateRoute(any(GeoCoordinate.class), any(GeoCoordinate.class));
    }

    @Test
    void e2e03MondayEveningPeakAddsTwentyPercent() {
        enablePeak();
        clock.set(MONDAY_EVENING);
        Session customer = user(UserRole.CUSTOMER);

        ResponseEntity<JsonNode> response = createQuote(customer, QUOTE_BODY);

        assertThat(response.getStatusCode().value()).isEqualTo(201);
        JsonNode data = data(response);
        assertPeakFare(data);
        UUID publicId = UUID.fromString(data.path("quotePublicId").asText());
        Quote quote = quotes.findByPublicIdAndCustomerPublicId(publicId, customer.user().getPublicId()).orElseThrow();
        assertThat(quote.getPricingSnapshot()).containsEntry("peakHourReason", "WEEKDAY_EVENING_PEAK");
    }

    @Test
    void e2e04MorningWindowEndIsExclusive() {
        enablePeak();
        clock.set(MONDAY_AFTER_MORNING);
        Session customer = user(UserRole.CUSTOMER);

        ResponseEntity<JsonNode> response = createQuote(customer, QUOTE_BODY);

        assertThat(response.getStatusCode().value()).isEqualTo(201);
        assertNormalFare(data(response));
        UUID publicId = UUID.fromString(data(response).path("quotePublicId").asText());
        Quote quote = quotes.findByPublicIdAndCustomerPublicId(publicId, customer.user().getPublicId()).orElseThrow();
        assertThat(quote.getPricingSnapshot()).containsEntry("peakHourReason", "OUTSIDE_PEAK_HOURS");
    }

    @Test
    void e2e05WeekendMorningUsesNormalFare() {
        enablePeak();
        clock.set(SATURDAY_MORNING);
        Session customer = user(UserRole.CUSTOMER);

        ResponseEntity<JsonNode> response = createQuote(customer, QUOTE_BODY);

        assertThat(response.getStatusCode().value()).isEqualTo(201);
        assertNormalFare(data(response));
        UUID publicId = UUID.fromString(data(response).path("quotePublicId").asText());
        Quote quote = quotes.findByPublicIdAndCustomerPublicId(publicId, customer.user().getPublicId()).orElseThrow();
        assertThat(quote.getPricingSnapshot()).containsEntry("peakHourReason", "NON_PEAK_DAY");
    }

    @Test
    void e2e06PolicyTimeAndPostPricingTtlUseDistinctInstants() {
        enablePeak();
        clock.set(T0_BEFORE_WINDOW_END);
        Session customer = user(UserRole.CUSTOMER);
        doAnswer(invocation -> {
            FareBreakdown fare = (FareBreakdown) invocation.callRealMethod();
            clock.set(T1_AFTER_WINDOW_END);
            return fare;
        }).when(pricing).calculate(eq(VehicleType.MOTORBIKE), any(RouteEstimate.class), eq(BigDecimal.ZERO),
                any(PeakHourPricingPolicy.Evaluation.class), any(WeatherPricingPolicy.Evaluation.class),
                any(BigDecimal.class));

        ResponseEntity<JsonNode> created = createQuote(customer, QUOTE_BODY);

        assertThat(created.getStatusCode().value()).isEqualTo(201);
        JsonNode data = data(created);
        assertPeakFare(data);
        UUID publicId = UUID.fromString(data.path("quotePublicId").asText());
        Quote quote = quotes.findByPublicIdAndCustomerPublicId(publicId, customer.user().getPublicId()).orElseThrow();
        assertThat(quote.getPricingSnapshot()).containsEntry("peakHourEvaluationTimestamp", T0_BEFORE_WINDOW_END.toString())
                .containsEntry("peakHourApplied", "true");
        assertThat(quote.getIssuedAt()).isEqualTo(T1_AFTER_WINDOW_END);
        assertThat(quote.getExpiresAt()).isEqualTo(T1_AFTER_WINDOW_END.plusSeconds(60));
        assertThat(quote.getFinalFare()).isEqualByComparingTo("19800.00");
        assertThat(quote.isUsableAt(T1_AFTER_WINDOW_END.plusSeconds(59))).isTrue();
        assertThat(quote.isUsableAt(T1_AFTER_WINDOW_END.plusSeconds(60))).isFalse();

        clock.set(T1_AFTER_WINDOW_END.plusSeconds(59));
        assertThat(data(get(QUOTES + "/" + publicId, customer)).path("status").asText()).isEqualTo("ISSUED");
        clock.set(T1_AFTER_WINDOW_END.plusSeconds(60));
        assertThat(data(get(QUOTES + "/" + publicId, customer)).path("status").asText()).isEqualTo("EXPIRED");
    }

    @Test
    void e2e07BookingReplayAndPolicyChangeKeepAcceptedQuotePrice() {
        enablePeak();
        clock.set(MONDAY_MORNING);
        Session customer = user(UserRole.CUSTOMER);
        JsonNode quoteData = data(createQuote(customer, QUOTE_BODY));
        UUID quotePublicId = UUID.fromString(quoteData.path("quotePublicId").asText());
        Quote originalQuote = quotes.findByPublicIdAndCustomerPublicId(quotePublicId,
                customer.user().getPublicId()).orElseThrow();
        var originalSnapshot = originalQuote.getPricingSnapshot();

        peakProperties.setMultiplier(new BigDecimal("1.50"));
        peakProperties.setPolicyVersion("PEAK_HOUR_V2");
        assertThat(peakPolicy.evaluate(MONDAY_MORNING).peakMultiplier()).isEqualByComparingTo("1.5000");

        String key = UUID.randomUUID().toString();
        String bookingBody = "{\"quotePublicId\":\"" + quotePublicId + "\"}";
        ResponseEntity<JsonNode> created = exchange(BOOKINGS, HttpMethod.POST, customer.token(), bookingBody, key);
        assertThat(created.getStatusCode().value()).isEqualTo(201);
        JsonNode bookingData = data(created);
        assertThat(bookingData.path("finalFare").decimalValue()).isEqualByComparingTo("19800.00");
        UUID bookingPublicId = UUID.fromString(bookingData.path("bookingPublicId").asText());

        Booking booking = bookings.findOwned(bookingPublicId, customer.user().getPublicId()).orElseThrow();
        assertThat(booking.getFinalFare()).isEqualTo(originalQuote.getFinalFare());
        assertThat(booking.getPricingSnapshot()).isEqualTo(originalSnapshot);
        Quote quoteAfterChange = quotes.findByPublicIdAndCustomerPublicId(quotePublicId,
                customer.user().getPublicId()).orElseThrow();
        assertThat(quoteAfterChange.getFinalFare()).isEqualTo(originalQuote.getFinalFare());
        assertThat(quoteAfterChange.getSurgeMultiplier()).isEqualTo(new BigDecimal("1.2000"));
        assertThat(quoteAfterChange.getPricingSnapshot()).isEqualTo(originalSnapshot);

        ResponseEntity<JsonNode> fetched = get(BOOKINGS + "/" + bookingPublicId, customer);
        assertThat(fetched.getStatusCode().value()).isEqualTo(200);
        assertThat(data(fetched).path("finalFare").decimalValue()).isEqualByComparingTo("19800.00");

        ResponseEntity<JsonNode> replay = exchange(BOOKINGS, HttpMethod.POST, customer.token(), bookingBody, key);
        assertThat(replay.getStatusCode().value()).isEqualTo(201);
        assertThat(data(replay).path("bookingPublicId").asText()).isEqualTo(bookingPublicId.toString());
        assertThat(bookings.countByQuoteId(originalQuote.getId())).isEqualTo(1);
    }

    @Test
    void e2e08JwtRolesRequestValidationAndResourceOwnershipAreEnforced() {
        enablePeak();
        clock.set(MONDAY_MORNING);
        ResponseEntity<JsonNode> unauthenticated = exchange(QUOTES, HttpMethod.POST, null, QUOTE_BODY, null);
        assertThat(unauthenticated.getStatusCode().value()).isEqualTo(401);

        Session driver = user(UserRole.DRIVER);
        ResponseEntity<JsonNode> driverQuote = createQuote(driver, QUOTE_BODY);
        assertThat(driverQuote.getStatusCode().value()).isEqualTo(403);

        Session owner = user(UserRole.CUSTOMER);
        String injected = QUOTE_BODY.replace("\"vehicleType\":\"MOTORBIKE\"",
                "\"vehicleType\":\"MOTORBIKE\",\"finalFare\":1,\"peakHourMultiplier\":99,"
                        + "\"pricingTimestamp\":\"2030-01-01T00:00:00Z\"");
        assertThat(createQuote(owner, injected).getStatusCode().value()).isEqualTo(400);

        JsonNode quoteData = data(createQuote(owner, QUOTE_BODY));
        UUID quotePublicId = UUID.fromString(quoteData.path("quotePublicId").asText());
        Session anotherCustomer = user(UserRole.CUSTOMER);
        assertThat(get(QUOTES + "/" + quotePublicId, anotherCustomer).getStatusCode().value()).isEqualTo(404);

        String bookingBody = "{\"quotePublicId\":\"" + quotePublicId + "\"}";
        ResponseEntity<JsonNode> bookingResponse = exchange(BOOKINGS, HttpMethod.POST, owner.token(), bookingBody,
                UUID.randomUUID().toString());
        assertThat(bookingResponse.getStatusCode().value()).isEqualTo(201);
        UUID bookingPublicId = UUID.fromString(data(bookingResponse).path("bookingPublicId").asText());
        assertThat(get(BOOKINGS + "/" + bookingPublicId, anotherCustomer).getStatusCode().value()).isEqualTo(404);
    }

    private void assertPeakFare(JsonNode data) {
        assertThat(data.path("baseFare").decimalValue()).isEqualByComparingTo("12000.00");
        assertThat(data.path("distanceFare").decimalValue()).isEqualByComparingTo("4500.00");
        assertThat(data.path("timeFare").decimalValue()).isEqualByComparingTo("0.00");
        assertThat(data.path("surgeMultiplier").decimalValue()).isEqualByComparingTo("1.2000");
        assertThat(data.path("surgeAmount").decimalValue()).isEqualByComparingTo("3300.00");
        assertThat(data.path("roundingAdjustment").decimalValue()).isEqualByComparingTo("0.00");
        assertThat(data.path("finalFare").decimalValue()).isEqualByComparingTo("19800.00");
    }

    private void assertNormalFare(JsonNode data) {
        assertThat(data.path("baseFare").decimalValue()).isEqualByComparingTo("12000.00");
        assertThat(data.path("distanceFare").decimalValue()).isEqualByComparingTo("4500.00");
        assertThat(data.path("surgeMultiplier").decimalValue()).isEqualByComparingTo("1.0000");
        assertThat(data.path("surgeAmount").decimalValue()).isEqualByComparingTo("0.00");
        assertThat(data.path("roundingAdjustment").decimalValue()).isEqualByComparingTo("0.00");
        assertThat(data.path("finalFare").decimalValue()).isEqualByComparingTo("16500.00");
    }

    private void enablePeak() {
        peakProperties.setEnabled(true);
    }

    private void resetPeakConfiguration() {
        peakProperties.setEnabled(false);
        peakProperties.setMultiplier(new BigDecimal("1.20"));
        peakProperties.setPolicyVersion("PEAK_HOUR_V1");
    }

    private ResponseEntity<JsonNode> createQuote(Session customer, String body) {
        return exchange(QUOTES, HttpMethod.POST, customer.token(), body, null);
    }

    private ResponseEntity<JsonNode> get(String path, Session customer) {
        return exchange(path, HttpMethod.GET, customer.token(), null, null);
    }

    private ResponseEntity<JsonNode> exchange(String path, HttpMethod method, String token, String body,
                                              String idempotencyKey) {
        MockHttpServletRequestBuilder request = method == HttpMethod.GET
                ? org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get(path)
                : org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post(path);
        if (body != null) request.contentType(MediaType.APPLICATION_JSON).content(body);
        if (token != null) request.header("Authorization", "Bearer " + token);
        if (idempotencyKey != null) request.header("Idempotency-Key", idempotencyKey);
        try {
            MvcResult result = http.perform(request).andReturn();
            String responseBody = result.getResponse().getContentAsString();
            JsonNode json = responseBody.isBlank() ? null : mapper.readTree(responseBody);
            return ResponseEntity.status(HttpStatus.valueOf(result.getResponse().getStatus())).body(json);
        } catch (Exception exception) {
            throw new AssertionError("REST request failed: " + method + " " + path, exception);
        }
    }

    private JsonNode data(ResponseEntity<JsonNode> response) {
        assertThat(response.getBody()).isNotNull();
        return response.getBody().path("data");
    }

    private Quote quote(JsonNode data, User owner) {
        return quotes.findByPublicIdAndCustomerPublicId(UUID.fromString(data.path("quotePublicId").asText()),
                owner.getPublicId()).orElseThrow();
    }

    private Session user(UserRole role) {
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "pricing-e2e-" + suffix + "@example.test", "hash", "Pricing API E2E");
        user.setRole(role);
        User saved = users.saveAndFlush(user);
        return new Session(saved, jwt.createAccessToken(saved));
    }

    private record Session(User user, String token) {
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class TestClockConfiguration {
        @Bean
        @Primary
        MutableTestClock testClock() {
            return new MutableTestClock();
        }
    }

    static class MutableTestClock extends Clock {
        private final AtomicReference<Instant> now = new AtomicReference<>(MONDAY_MORNING);

        void set(Instant instant) {
            now.set(instant);
        }

        @Override
        public ZoneId getZone() {
            return ZoneOffset.UTC;
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return Clock.fixed(now.get(), zone);
        }

        @Override
        public Instant instant() {
            return now.get();
        }
    }
}
