package com.gomove.pricing;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.auth.domain.UserRole;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.common.exception.DomainException;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.Quote;
import com.gomove.pricing.domain.QuoteRepository;
import com.gomove.pricing.domain.QuoteStatus;
import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.routing.RoutingService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@AutoConfigureMockMvc
class QuoteIntegrationTest extends BaseIntegrationTest {
    private static final String PATH = "/api/v1/quotes";
    private static final String REQUEST = """
            {"pickupLatitude":21.0287,"pickupLongitude":105.8524,
             "dropoffLatitude":21.0245,"dropoffLongitude":105.8576,"vehicleType":"MOTORBIKE"}
            """;
    private static final Instant FIXED = Instant.parse("2026-10-08T03:00:00Z");

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired UserRepository users;
    @Autowired QuoteRepository quotes;
    @Autowired JwtTokenProvider jwt;
    @Autowired JdbcTemplate jdbc;
    @MockitoBean RoutingService routing;
    @MockitoBean Clock clock;

    @BeforeEach
    void setUp() {
        when(clock.instant()).thenReturn(FIXED);
        when(routing.calculateRoute(any(GeoCoordinate.class), any(GeoCoordinate.class)))
                .thenAnswer(invocation -> {
                    assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
                    return new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "TEST_ROUTER");
                });
    }

    @Test
    void realSecurityFilterAndOwnershipProtectCreateAndRetrieve() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        User otherCustomer = user(UserRole.CUSTOMER);
        User driver = user(UserRole.DRIVER);

        mvc.perform(post(PATH).contentType(MediaType.APPLICATION_JSON).content(REQUEST))
                .andExpect(status().isUnauthorized());
        mvc.perform(post(PATH).header("Authorization", bearer(driver))
                        .contentType(MediaType.APPLICATION_JSON).content(REQUEST))
                .andExpect(status().isForbidden());

        String created = mvc.perform(post(PATH).header("Authorization", bearer(customer))
                        .contentType(MediaType.APPLICATION_JSON).content(REQUEST))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.data.finalFare").value(35400.00))
                .andExpect(jsonPath("$.data.surgeAmount").value(0.00))
                .andExpect(jsonPath("$.data.roundingAdjustment").value(0.00))
                .andExpect(jsonPath("$.data.pricingEngineVersion").value("MVP_V1"))
                .andExpect(jsonPath("$.data.status").value("ISSUED"))
                .andExpect(jsonPath("$.data.id").doesNotExist())
                .andExpect(jsonPath("$.data.customerId").doesNotExist())
                .andReturn().getResponse().getContentAsString();
        UUID publicId = UUID.fromString(mapper.readTree(created).path("data").path("quotePublicId").asText());

        mvc.perform(get(PATH + "/" + publicId)).andExpect(status().isUnauthorized());
        mvc.perform(get(PATH + "/" + publicId).header("Authorization", bearer(driver)))
                .andExpect(status().isForbidden());
        mvc.perform(get(PATH + "/" + publicId).header("Authorization", bearer(otherCustomer)))
                .andExpect(status().isNotFound()).andExpect(jsonPath("$.code").value("QUOTE_NOT_FOUND"));
        mvc.perform(get(PATH + "/" + publicId).header("Authorization", bearer(customer)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.finalFare").value(35400.00))
                .andExpect(jsonPath("$.data.status").value("ISSUED"));
        verify(routing, times(1)).calculateRoute(any(), any());
    }

    @Test
    void requestCannotSupplyIdentityFareOrRouteFields() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        User other = user(UserRole.CUSTOMER);
        String tampered = REQUEST.replace("\"vehicleType\":\"MOTORBIKE\"",
                "\"vehicleType\":\"MOTORBIKE\",\"customerId\":" + other.getId() + ",\"finalFare\":1");
        long before = quotes.count();

        mvc.perform(post(PATH).header("Authorization", bearer(customer))
                        .contentType(MediaType.APPLICATION_JSON).content(tampered))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("VALIDATION_ERROR"));
        assertThat(quotes.count()).isEqualTo(before);
    }

    @Test
    void malformedAndOutOfRangeRequestsAreRejected() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        String auth = bearer(customer);

        mvc.perform(post(PATH).header("Authorization", auth).contentType(MediaType.APPLICATION_JSON).content("{"))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.code").value("VALIDATION_ERROR"));
        mvc.perform(post(PATH).header("Authorization", auth).contentType(MediaType.APPLICATION_JSON)
                        .content(REQUEST.replace("21.0287", "91.0")))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.code").value("VALIDATION_ERROR"));
        mvc.perform(post(PATH).header("Authorization", auth).contentType(MediaType.APPLICATION_JSON)
                        .content(REQUEST.replace("MOTORBIKE", "HELICOPTER")))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.code").value("VALIDATION_ERROR"));
        mvc.perform(post(PATH).header("Authorization", auth).contentType(MediaType.APPLICATION_JSON)
                        .content(REQUEST.replace("\"pickupLatitude\":21.0287,", "")))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.code").value("VALIDATION_ERROR"));
    }

    @Test
    void routingFailureCreatesNoQuoteAndUsesApplicationError() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        when(routing.calculateRoute(any(), any()))
                .thenThrow(new DomainException(HttpStatus.SERVICE_UNAVAILABLE,
                        "ROUTING_UNAVAILABLE", "Road routing is temporarily unavailable"));
        long before = quotes.count();

        mvc.perform(post(PATH).header("Authorization", bearer(customer))
                        .contentType(MediaType.APPLICATION_JSON).content(REQUEST))
                .andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.code").value("ROUTING_UNAVAILABLE"));
        assertThat(quotes.count()).isEqualTo(before);
    }

    @Test
    void quoteIsExpiredAtExactSixtySecondBoundaryWithoutChangingStoredStatus() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        JsonNode created = mapper.readTree(mvc.perform(post(PATH).header("Authorization", bearer(customer))
                        .contentType(MediaType.APPLICATION_JSON).content(REQUEST))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        UUID publicId = UUID.fromString(created.path("data").path("quotePublicId").asText());
        when(clock.instant()).thenReturn(FIXED.plusSeconds(60));

        mvc.perform(get(PATH + "/" + publicId).header("Authorization", bearer(customer)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.status").value("EXPIRED"))
                .andExpect(jsonPath("$.data.finalFare").value(35400.00));
        assertThat(quotes.findByPublicIdAndCustomerPublicId(publicId, customer.getPublicId()).orElseThrow().getStatus())
                .isEqualTo(QuoteStatus.ISSUED);
    }

    @Test
    void nonzeroReconciliationSurvivesApiPersistenceAndRetrieval() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        doReturn(new RouteEstimate(new BigDecimal("1000.111"), new BigDecimal("60"), "TEST_ROUTER"))
                .when(routing).calculateRoute(any(), any());
        JsonNode created = mapper.readTree(mvc.perform(post(PATH).header("Authorization", bearer(customer))
                        .contentType(MediaType.APPLICATION_JSON).content(REQUEST))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).path("data");
        UUID publicId = UUID.fromString(created.path("quotePublicId").asText());

        assertThat(created.path("distanceFare").decimalValue()).isEqualByComparingTo(new BigDecimal("4500.50"));
        assertThat(created.path("roundingAdjustment").decimalValue()).isEqualByComparingTo(new BigDecimal("-0.50"));
        assertThat(created.path("finalFare").decimalValue()).isEqualByComparingTo(new BigDecimal("16500.00"));
        assertReconciles(created);

        Quote saved = quotes.findByPublicIdAndCustomerPublicId(publicId, customer.getPublicId()).orElseThrow();
        assertThat(saved.getRoundingAdjustment()).isEqualTo(new BigDecimal("-0.50"));
        assertThat(saved.getSurgeAmount()).isEqualTo(new BigDecimal("0.00"));
        assertThat(saved.getPricingSnapshot()).containsEntry("roundingAdjustment", "-0.50");
        assertThat(new BigDecimal(saved.getPricingSnapshot().get("rawDistanceFare")))
                .isEqualByComparingTo(new BigDecimal("4500.4995"));
        assertThat(saved.getPricingSnapshot()).containsKeys("rawSubtotal", "rawSurgeAmount",
                "rawSurgedSubtotal", "rawFinalBeforeRounding");
        assertThatThrownBy(() -> saved.getPricingSnapshot().put("finalFare", "1.00"))
                .isInstanceOf(UnsupportedOperationException.class);

        JsonNode fetched = mapper.readTree(mvc.perform(get(PATH + "/" + publicId)
                        .header("Authorization", bearer(customer)))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString()).path("data");
        assertThat(fetched.path("roundingAdjustment").decimalValue()).isEqualByComparingTo(new BigDecimal("-0.50"));
        assertReconciles(fetched);
        verify(routing, times(1)).calculateRoute(any(), any());
    }

    @Test
    void v9SchemaAndSnapshotRoundTripRemainPrecise() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        JsonNode created = mapper.readTree(mvc.perform(post(PATH).header("Authorization", bearer(customer))
                        .contentType(MediaType.APPLICATION_JSON).content(REQUEST))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        UUID publicId = UUID.fromString(created.path("data").path("quotePublicId").asText());
        Quote quote = quotes.findByPublicIdAndCustomerPublicId(publicId, customer.getPublicId()).orElseThrow();

        assertThat(quote.getFinalFare()).isEqualTo(new BigDecimal("35400.00"));
        assertThat(quote.getSurgeAmount()).isEqualTo(new BigDecimal("0.00"));
        assertThat(quote.getRoundingAdjustment()).isEqualTo(new BigDecimal("0.00"));
        assertThat(quote.getPricingSnapshot()).containsEntry("pricingEngineVersion", "MVP_V1")
                .containsEntry("pricePerKm", "4500.00")
                .containsEntry("finalFare", "35400.00");
        assertThat(quote.getIssuedAt()).isEqualTo(FIXED);
        assertThat(quote.getExpiresAt()).isEqualTo(FIXED.plusSeconds(60));
        assertThat(quote.getStatus()).isEqualTo(QuoteStatus.ISSUED);
        assertThat(quote.getPickupLocation().getSRID()).isEqualTo(4326);
        assertThat(quote.getDropoffLocation().getSRID()).isEqualTo(4326);

        assertThat(jdbc.queryForObject("SELECT to_regclass('public.quotes') IS NOT NULL", Boolean.class)).isTrue();
        assertThat(jdbc.queryForObject("SELECT version FROM flyway_schema_history WHERE success=TRUE ORDER BY installed_rank DESC LIMIT 1", String.class))
                .isEqualTo("9");
        assertThat(jdbc.queryForObject("""
                SELECT data_type FROM information_schema.columns
                WHERE table_name='quotes' AND column_name='pricing_snapshot'
                """, String.class)).isEqualTo("jsonb");
        for (String column : new String[]{"pickup_location", "dropoff_location"}) {
            assertThat(jdbc.queryForObject("""
                    SELECT format_type(a.atttypid, a.atttypmod)
                    FROM pg_attribute a WHERE a.attrelid='quotes'::regclass AND a.attname=?
                    """, String.class, column)).containsIgnoringCase("geography(Point,4326)");
        }
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM pg_constraint
                WHERE conrelid='quotes'::regclass AND contype='u' AND conkey @> ARRAY[
                    (SELECT attnum FROM pg_attribute WHERE attrelid='quotes'::regclass AND attname='public_id')
                ]::smallint[]
                """, Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM pg_constraint
                WHERE conrelid='quotes'::regclass AND contype='f'
                """, Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM pg_indexes
                WHERE tablename='quotes' AND indexname='idx_quotes_customer_issued_at'
                """, Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM pg_constraint
                WHERE conrelid='quotes'::regclass AND conname='chk_quotes_fare_reconciliation'
                """, Integer.class)).isEqualTo(1);

        assertThatThrownBy(() -> jdbc.update("UPDATE quotes SET final_fare=-1 WHERE public_id=?", publicId))
                .isInstanceOf(DataIntegrityViolationException.class);
        assertThatThrownBy(() -> jdbc.update("UPDATE quotes SET rounding_adjustment=1 WHERE public_id=?", publicId))
                .isInstanceOf(DataIntegrityViolationException.class);
        assertThatThrownBy(() -> jdbc.update("UPDATE quotes SET status='BOGUS' WHERE public_id=?", publicId))
                .isInstanceOf(DataIntegrityViolationException.class);
        assertThatThrownBy(() -> jdbc.update("UPDATE quotes SET customer_id=-1 WHERE public_id=?", publicId))
                .isInstanceOf(DataIntegrityViolationException.class);
    }

    private User user(UserRole role) {
        String unique = UUID.randomUUID().toString().substring(0, 8);
        User user = users.saveAndFlush(new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "quote-" + unique + "@example.test", "hash", "Quote Test"));
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private String bearer(User user) {
        return "Bearer " + jwt.createAccessToken(user);
    }

    private void assertReconciles(JsonNode response) {
        BigDecimal sum = response.path("baseFare").decimalValue()
                .add(response.path("distanceFare").decimalValue())
                .add(response.path("timeFare").decimalValue())
                .add(response.path("surcharge").decimalValue())
                .add(response.path("surgeAmount").decimalValue())
                .subtract(response.path("discountAmount").decimalValue())
                .add(response.path("roundingAdjustment").decimalValue());
        assertThat(sum).isEqualByComparingTo(response.path("finalFare").decimalValue());
    }
}
