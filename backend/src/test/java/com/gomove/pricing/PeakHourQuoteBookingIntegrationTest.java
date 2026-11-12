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
import com.gomove.pricing.domain.QuoteStatus;
import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.engine.PeakHourPricingPolicy;
import com.gomove.pricing.engine.PeakHourPricingProperties;
import com.gomove.pricing.routing.RoutingService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@AutoConfigureMockMvc
@org.springframework.boot.test.context.SpringBootTest(properties = "gomove.pricing.peak-hour.enabled=true")
class PeakHourQuoteBookingIntegrationTest extends BaseIntegrationTest {
    private static final String QUOTES = "/api/v1/quotes";
    private static final String BOOKINGS = "/api/v1/bookings";
    private static final String QUOTE_REQUEST = """
            {"pickupLatitude":21.0287,"pickupLongitude":105.8524,
             "dropoffLatitude":21.0245,"dropoffLongitude":105.8576,"vehicleType":"MOTORBIKE"}
            """;
    private static final Instant BEFORE_WINDOW_END = Instant.parse("2026-10-05T01:59:45Z");
    private static final Instant AFTER_WINDOW_END = Instant.parse("2026-10-05T02:00:15Z");

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired UserRepository users;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired JwtTokenProvider jwt;
    @Autowired PeakHourPricingPolicy peakHourPricing;
    @Autowired PeakHourPricingProperties pricingProperties;
    @MockitoBean RoutingService routing;
    @MockitoBean Clock clock;

    @BeforeEach
    void setUp() {
        pricingProperties.setMultiplier(new BigDecimal("1.20"));
        pricingProperties.setPolicyVersion("PEAK_HOUR_V1");
        when(clock.instant()).thenReturn(BEFORE_WINDOW_END);
        when(routing.calculateRoute(any(GeoCoordinate.class), any(GeoCoordinate.class)))
                .thenReturn(new RouteEstimate(new BigDecimal("1000"), new BigDecimal("60"), "TEST_ROUTER"));
    }

    @AfterEach
    void restorePricingConfiguration() {
        pricingProperties.setMultiplier(new BigDecimal("1.20"));
        pricingProperties.setPolicyVersion("PEAK_HOUR_V1");
    }

    @Test
    void peakQuoteSnapshotIsPersistedAndBookingRetainsFareAfterWindowEnds() throws Exception {
        User customer = user();
        when(clock.instant()).thenReturn(BEFORE_WINDOW_END, AFTER_WINDOW_END, AFTER_WINDOW_END);
        JsonNode quoteResponse = mapper.readTree(mvc.perform(post(QUOTES).header("Authorization", bearer(customer))
                        .contentType(MediaType.APPLICATION_JSON).content(QUOTE_REQUEST))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.data.surgeMultiplier").value(1.2))
                .andExpect(jsonPath("$.data.surgeAmount").value(3300.00))
                .andExpect(jsonPath("$.data.finalFare").value(19800.00))
                .andReturn().getResponse().getContentAsString()).path("data");

        UUID quotePublicId = UUID.fromString(quoteResponse.path("quotePublicId").asText());
        Quote quote = quotes.findByPublicIdAndCustomerPublicId(quotePublicId, customer.getPublicId()).orElseThrow();
        assertThat(quote.getIssuedAt()).isEqualTo(AFTER_WINDOW_END);
        assertThat(quote.getExpiresAt()).isEqualTo(AFTER_WINDOW_END.plusSeconds(60));
        assertThat(quote.getPricingSnapshot()).containsEntry("peakHourPolicyVersion", "PEAK_HOUR_V1")
                .containsEntry("peakHourEvaluationTimestamp", BEFORE_WINDOW_END.toString())
                .containsEntry("peakHourTimezone", "Asia/Ho_Chi_Minh")
                .containsEntry("peakHourMultiplier", "1.2000")
                .containsEntry("configuredPeakHourMultiplier", "1.20")
                .containsEntry("peakHourApplied", "true")
                .containsEntry("peakHourReason", "WEEKDAY_MORNING_PEAK")
                .containsEntry("tariffSurgeMultiplier", "1.0000")
                .containsEntry("effectiveSurgeMultiplier", "1.2000");
        var originalSnapshot = quote.getPricingSnapshot();

        pricingProperties.setMultiplier(new BigDecimal("1.50"));
        pricingProperties.setPolicyVersion("PEAK_HOUR_V2");
        PeakHourPricingPolicy.Evaluation updatedPolicy = peakHourPricing.evaluate(BEFORE_WINDOW_END);
        assertThat(updatedPolicy.policyVersion()).isEqualTo("PEAK_HOUR_V2");
        assertThat(updatedPolicy.peakMultiplier()).isEqualTo(new BigDecimal("1.5000"));

        when(clock.instant()).thenReturn(AFTER_WINDOW_END.plusSeconds(59));
        mvc.perform(get(QUOTES + "/" + quotePublicId).header("Authorization", bearer(customer)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.status").value("ISSUED"))
                .andExpect(jsonPath("$.data.surgeMultiplier").value(1.2))
                .andExpect(jsonPath("$.data.finalFare").value(19800.00));

        when(clock.instant()).thenReturn(AFTER_WINDOW_END.plusSeconds(60));
        mvc.perform(get(QUOTES + "/" + quotePublicId).header("Authorization", bearer(customer)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.status").value("EXPIRED"))
                .andExpect(jsonPath("$.data.finalFare").value(19800.00));
        assertThat(quotes.findByPublicIdAndCustomerPublicId(quotePublicId, customer.getPublicId())
                .orElseThrow().getStatus()).isEqualTo(QuoteStatus.ISSUED);

        Quote persistedAfterPolicyChange = quotes.findByPublicIdAndCustomerPublicId(quotePublicId,
                customer.getPublicId()).orElseThrow();
        assertThat(persistedAfterPolicyChange.getFinalFare()).isEqualTo(new BigDecimal("19800.00"));
        assertThat(persistedAfterPolicyChange.getSurgeMultiplier()).isEqualTo(new BigDecimal("1.2000"));
        assertThat(persistedAfterPolicyChange.getPricingSnapshot()).isEqualTo(originalSnapshot);

        // The old Quote stays usable up to the exact exclusive expiry boundary.
        when(clock.instant()).thenReturn(AFTER_WINDOW_END.plusSeconds(59));
        JsonNode bookingResponse = mapper.readTree(mvc.perform(post(BOOKINGS)
                        .header("Authorization", bearer(customer))
                        .header("Idempotency-Key", UUID.randomUUID().toString())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"quotePublicId\":\"" + quotePublicId + "\"}"))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.data.finalFare").value(19800.00))
                .andReturn().getResponse().getContentAsString()).path("data");

        UUID bookingPublicId = UUID.fromString(bookingResponse.path("bookingPublicId").asText());
        Booking booking = bookings.findOwned(bookingPublicId, customer.getPublicId()).orElseThrow();
        assertThat(booking.getFinalFare()).isEqualTo(persistedAfterPolicyChange.getFinalFare());
        assertThat(booking.getPricingSnapshot()).isEqualTo(persistedAfterPolicyChange.getPricingSnapshot());
        assertThat(booking.getPricingSnapshot()).containsEntry("peakHourEvaluationTimestamp", BEFORE_WINDOW_END.toString());
        assertThatThrownBySnapshotMutation(booking);

        mvc.perform(get(BOOKINGS + "/" + bookingPublicId).header("Authorization", bearer(customer)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.finalFare").value(19800.00));
        verify(routing, times(1)).calculateRoute(any(), any());
    }

    private void assertThatThrownBySnapshotMutation(Booking booking) {
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> booking.getPricingSnapshot().put("finalFare", "1.00"))
                .isInstanceOf(UnsupportedOperationException.class);
    }

    private User user() {
        String unique = UUID.randomUUID().toString().substring(0, 8);
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "peak-" + unique + "@example.test", "hash", "Peak Quote Test");
        user.setRole(UserRole.CUSTOMER);
        return users.saveAndFlush(user);
    }

    private String bearer(User user) {
        return "Bearer " + jwt.createAccessToken(user);
    }
}
