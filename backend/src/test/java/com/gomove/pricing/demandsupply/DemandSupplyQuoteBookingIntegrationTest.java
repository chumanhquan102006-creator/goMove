package com.gomove.pricing.demandsupply;

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
import com.gomove.pricing.engine.PeakHourPricingProperties;
import com.gomove.pricing.routing.RoutingService;
import com.gomove.pricing.weather.WeatherPricingProperties;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** API integration for M2B using real JWT, JPA/Flyway and deterministic routing/metrics boundaries. */
@SpringBootTest(properties = {
        "gomove.pricing.demand-supply.enabled=true",
        "gomove.pricing.peak-hour.enabled=false",
        "gomove.pricing.weather.enabled=false"
})
@AutoConfigureMockMvc
@Import(DemandSupplyQuoteBookingIntegrationTest.TestDependencies.class)
class DemandSupplyQuoteBookingIntegrationTest extends BaseIntegrationTest {
    private static final String QUOTES = "/api/v1/quotes";
    private static final String BOOKINGS = "/api/v1/bookings";
    private static final String QUOTE_BODY = """
            {"pickupLatitude":-30.0,"pickupLongitude":-80.0,
             "dropoffLatitude":-30.01,"dropoffLongitude":-80.01,"vehicleType":"MOTORBIKE"}
            """;
    private static final Instant NOW = Instant.parse("2030-01-01T01:00:00Z");
    private static final DemandSupplyMetrics HIGH_DEMAND = DemandSupplyMetrics.available(8, 1, 1, 1);

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired UserRepository users;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired JwtTokenProvider jwt;
    @Autowired DemandSupplyPricingProperties demandProperties;
    @Autowired PeakHourPricingProperties peakProperties;
    @Autowired WeatherPricingProperties weatherProperties;
    @Autowired MutableProvider demandProvider;
    @Autowired MutableClock clock;

    @BeforeEach
    void resetDeterministicInputs() {
        demandProperties.setEnabled(true);
        demandProperties.setPolicyVersion("DEMAND_SUPPLY_V1");
        demandProperties.setModerateMultiplier(new BigDecimal("1.1000"));
        demandProperties.setHighMultiplier(new BigDecimal("1.2000"));
        demandProperties.setMaximumMultiplier(new BigDecimal("1.2000"));
        peakProperties.setEnabled(false);
        peakProperties.setMultiplier(new BigDecimal("1.20"));
        peakProperties.setPolicyVersion("PEAK_HOUR_V1");
        weatherProperties.setEnabled(false);
        demandProvider.metrics.set(HIGH_DEMAND);
        demandProvider.calls.set(0);
        clock.set(NOW);
    }

    @AfterEach
    void restoreConfiguration() {
        demandProperties.setEnabled(false);
        demandProperties.setPolicyVersion("DEMAND_SUPPLY_V1");
        demandProperties.setModerateMultiplier(new BigDecimal("1.1000"));
        demandProperties.setHighMultiplier(new BigDecimal("1.2000"));
        demandProperties.setMaximumMultiplier(new BigDecimal("1.2000"));
        peakProperties.setEnabled(false);
        peakProperties.setMultiplier(new BigDecimal("1.20"));
        peakProperties.setPolicyVersion("PEAK_HOUR_V1");
        weatherProperties.setEnabled(false);
    }

    @Test
    void quoteSnapshotAndFareAreImmutableWhenPolicyChangesBeforeBooking() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        String token = bearer(customer);

        JsonNode created = data(mvc.perform(post(QUOTES).header("Authorization", token)
                        .contentType(MediaType.APPLICATION_JSON).content(QUOTE_BODY))
                .andExpect(result -> assertThat(result.getResponse().getStatus()).isEqualTo(201))
                .andReturn());
        UUID quotePublicId = UUID.fromString(created.path("quotePublicId").asText());
        Quote quoteBeforeChange = quotes.findByPublicIdAndCustomerPublicId(quotePublicId,
                customer.getPublicId()).orElseThrow();
        var acceptedSnapshot = quoteBeforeChange.getPricingSnapshot();

        assertThat(created.path("finalFare").decimalValue()).isEqualByComparingTo("19800.00");
        assertThat(acceptedSnapshot).containsEntry("demandSupplyPolicyVersion", "DEMAND_SUPPLY_V1")
                .containsEntry("demandSupplyEvaluationTimestamp", NOW.toString())
                .containsEntry("demandSupplyDataStatus", "AVAILABLE")
                .containsEntry("demandCount", "8")
                .containsEntry("availableDriverCount", "1")
                .containsEntry("requestedDemandSupplyMultiplier", "1.2000")
                .containsEntry("actualDemandFareDifferenceVnd", "3300.00")
                .containsEntry("finalEffectiveMultiplier", "1.2000");
        assertThat(quoteBeforeChange.getSurgeMultiplier()).isEqualByComparingTo("1.2000");
        assertThat(demandProvider.calls).hasValue(1);

        // A later policy update applies to new Quotes only; it cannot reprice this accepted Quote.
        demandProperties.setPolicyVersion("DEMAND_SUPPLY_V2");
        demandProperties.setHighMultiplier(new BigDecimal("1.3000"));
        demandProperties.setMaximumMultiplier(new BigDecimal("1.3000"));
        JsonNode laterQuote = data(mvc.perform(post(QUOTES).header("Authorization", token)
                        .contentType(MediaType.APPLICATION_JSON).content(QUOTE_BODY))
                .andExpect(result -> assertThat(result.getResponse().getStatus()).isEqualTo(201))
                .andReturn());
        assertThat(laterQuote.path("finalFare").decimalValue()).isEqualByComparingTo("21450.00");
        assertThat(quoteBeforeChange.getFinalFare()).isEqualByComparingTo("19800.00");
        assertThat(quoteBeforeChange.getPricingSnapshot()).isEqualTo(acceptedSnapshot);
        demandProvider.metrics.set(DemandSupplyMetrics.available(0, 0, 0, 0));

        String idempotencyKey = UUID.randomUUID().toString();
        String bookingBody = "{\"quotePublicId\":\"" + quotePublicId + "\"}";
        JsonNode bookingResponse = data(mvc.perform(post(BOOKINGS).header("Authorization", token)
                        .header("Idempotency-Key", idempotencyKey)
                        .contentType(MediaType.APPLICATION_JSON).content(bookingBody))
                .andExpect(result -> assertThat(result.getResponse().getStatus()).isEqualTo(201))
                .andReturn());
        UUID bookingPublicId = UUID.fromString(bookingResponse.path("bookingPublicId").asText());

        Booking booking = bookings.findOwned(bookingPublicId, customer.getPublicId()).orElseThrow();
        assertThat(booking.getFinalFare()).isEqualByComparingTo("19800.00");
        assertThat(booking.getPricingSnapshot()).isEqualTo(acceptedSnapshot);
        JsonNode fetchedBooking = data(mvc.perform(get(BOOKINGS + "/" + bookingPublicId)
                        .header("Authorization", token))
                .andExpect(result -> assertThat(result.getResponse().getStatus()).isEqualTo(200))
                .andReturn());
        assertThat(fetchedBooking.path("finalFare").decimalValue()).isEqualByComparingTo("19800.00");

        JsonNode replay = data(mvc.perform(post(BOOKINGS).header("Authorization", token)
                        .header("Idempotency-Key", idempotencyKey)
                        .contentType(MediaType.APPLICATION_JSON).content(bookingBody))
                .andExpect(result -> assertThat(result.getResponse().getStatus()).isEqualTo(201))
                .andReturn());
        assertThat(replay.path("bookingPublicId").asText()).isEqualTo(bookingPublicId.toString());
        assertThat(bookings.countByQuoteId(quoteBeforeChange.getId())).isEqualTo(1);
        assertThat(quoteBeforeChange.getPricingSnapshot()).isEqualTo(booking.getPricingSnapshot());
    }

    @Test
    void disabledM2bLeavesPeakHourM2aPricingAndSnapshotUnchanged() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        demandProperties.setEnabled(false);
        peakProperties.setEnabled(true);
        clock.set(Instant.parse("2030-01-07T01:30:00Z")); // Monday 08:30 in Vietnam.

        JsonNode created = data(mvc.perform(post(QUOTES).header("Authorization", bearer(customer))
                        .contentType(MediaType.APPLICATION_JSON).content(QUOTE_BODY))
                .andExpect(result -> assertThat(result.getResponse().getStatus()).isEqualTo(201))
                .andReturn());
        UUID quotePublicId = UUID.fromString(created.path("quotePublicId").asText());
        Quote quote = quotes.findByPublicIdAndCustomerPublicId(quotePublicId, customer.getPublicId()).orElseThrow();

        assertThat(created.path("finalFare").decimalValue()).isEqualByComparingTo("19800.00");
        assertThat(quote.getPricingSnapshot()).containsEntry("peakHourApplied", "true")
                .containsEntry("effectiveSurgeMultiplier", "1.2000")
                .doesNotContainKey("demandSupplyPolicyVersion");
        assertThat(demandProvider.calls).hasValue(0);
    }

    @Test
    void realJwtAuthorizationOwnershipAndClientPricingFieldsRemainProtected() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        User other = user(UserRole.CUSTOMER);
        User driver = user(UserRole.DRIVER);

        mvc.perform(post(QUOTES).contentType(MediaType.APPLICATION_JSON).content(QUOTE_BODY))
                .andExpect(result -> assertThat(result.getResponse().getStatus()).isEqualTo(401));
        mvc.perform(post(QUOTES).header("Authorization", bearer(driver))
                        .contentType(MediaType.APPLICATION_JSON).content(QUOTE_BODY))
                .andExpect(result -> assertThat(result.getResponse().getStatus()).isEqualTo(403));

        String injected = QUOTE_BODY.replace("\"vehicleType\":\"MOTORBIKE\"",
                "\"vehicleType\":\"MOTORBIKE\",\"finalFare\":1,\"demandSupplyMultiplier\":99,"
                        + "\"demandSupplyEvaluationTimestamp\":\"2020-01-01T00:00:00Z\"");
        mvc.perform(post(QUOTES).header("Authorization", bearer(customer))
                        .contentType(MediaType.APPLICATION_JSON).content(injected))
                .andExpect(result -> assertThat(result.getResponse().getStatus()).isEqualTo(400));

        JsonNode created = data(mvc.perform(post(QUOTES).header("Authorization", bearer(customer))
                        .contentType(MediaType.APPLICATION_JSON).content(QUOTE_BODY))
                .andExpect(result -> assertThat(result.getResponse().getStatus()).isEqualTo(201))
                .andReturn());
        UUID quotePublicId = UUID.fromString(created.path("quotePublicId").asText());
        mvc.perform(get(QUOTES + "/" + quotePublicId).header("Authorization", bearer(other)))
                .andExpect(result -> assertThat(result.getResponse().getStatus()).isEqualTo(404));

        String key = UUID.randomUUID().toString();
        JsonNode booking = data(mvc.perform(post(BOOKINGS).header("Authorization", bearer(customer))
                        .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"quotePublicId\":\"" + quotePublicId + "\"}"))
                .andExpect(result -> assertThat(result.getResponse().getStatus()).isEqualTo(201))
                .andReturn());
        UUID bookingPublicId = UUID.fromString(booking.path("bookingPublicId").asText());
        mvc.perform(get(BOOKINGS + "/" + bookingPublicId).header("Authorization", bearer(other)))
                .andExpect(result -> assertThat(result.getResponse().getStatus()).isEqualTo(404));
    }

    private JsonNode data(MvcResult result) throws Exception {
        JsonNode response = mapper.readTree(result.getResponse().getContentAsString());
        return response.path("data");
    }

    private User user(UserRole role) {
        String unique = UUID.randomUUID().toString().substring(0, 8);
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "m2b-api-" + unique + "@example.test", "test-hash", "M2B API Test");
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private String bearer(User user) {
        return "Bearer " + jwt.createAccessToken(user);
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class TestDependencies {
        @Bean
        @Primary
        MutableClock mutableClock() {
            return new MutableClock();
        }

        @Bean
        @Primary
        RoutingService deterministicRoutingService() {
            return new RoutingService() {
                @Override
                public RouteEstimate calculateRoute(GeoCoordinate pickup, GeoCoordinate dropoff) {
                    return route();
                }

                @Override
                public RouteEstimate calculateTravelMetrics(GeoCoordinate origin, GeoCoordinate destination) {
                    return route();
                }

                private RouteEstimate route() {
                    return new RouteEstimate(new BigDecimal("1000"), new BigDecimal("60"), "M2B_TEST_ROUTER");
                }
            };
        }

        @Bean
        @Primary
        MutableProvider deterministicDemandSupplyProvider() {
            return new MutableProvider();
        }
    }

    static class MutableProvider implements DemandSupplyProvider {
        private final AtomicReference<DemandSupplyMetrics> metrics = new AtomicReference<>(HIGH_DEMAND);
        private final AtomicInteger calls = new AtomicInteger();

        @Override
        public DemandSupplyMetrics snapshot(GeoCoordinate pickup, VehicleType vehicleType, Instant evaluatedAt) {
            calls.incrementAndGet();
            return metrics.get();
        }
    }

    static class MutableClock extends Clock {
        private final AtomicReference<Instant> now = new AtomicReference<>(NOW);

        void set(Instant instant) { now.set(instant); }

        @Override public ZoneId getZone() { return ZoneOffset.UTC; }
        @Override public Clock withZone(ZoneId zone) { return Clock.fixed(now.get(), zone); }
        @Override public Instant instant() { return now.get(); }
    }
}
