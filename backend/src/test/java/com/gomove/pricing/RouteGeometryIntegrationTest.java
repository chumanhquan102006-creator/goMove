package com.gomove.pricing;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.auth.domain.UserRole;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.booking.domain.BookingRepository;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.driver.domain.Driver;
import com.gomove.driver.domain.DriverApprovalStatus;
import com.gomove.driver.domain.DriverOperatingStatus;
import com.gomove.driver.domain.DriverRepository;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.Quote;
import com.gomove.pricing.domain.QuoteRepository;
import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.domain.RouteGeometry;
import com.gomove.pricing.engine.PricingEngine;
import com.gomove.pricing.routing.RoutingService;
import com.gomove.vehicle.domain.Vehicle;
import com.gomove.vehicle.domain.VehicleRepository;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.dao.DataAccessException;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Clock;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@AutoConfigureMockMvc
class RouteGeometryIntegrationTest extends BaseIntegrationTest {
    private static final Instant NOW = Instant.parse("2026-10-27T03:00:00Z");
    private static final String QUOTES = "/api/v1/quotes";
    private static final String BOOKINGS = "/api/v1/bookings";
    private static final String QUOTE_REQUEST = """
            {"pickupLatitude":21.0287,"pickupLongitude":105.8524,
             "dropoffLatitude":21.0245,"dropoffLongitude":105.8576,"vehicleType":"MOTORBIKE"}
            """;

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired UserRepository users;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired DriverRepository drivers;
    @Autowired VehicleRepository vehicles;
    @Autowired PricingEngine pricing;
    @Autowired JwtTokenProvider jwt;
    @Autowired JdbcTemplate jdbc;
    @MockitoBean RoutingService routing;
    @MockitoBean Clock clock;

    @BeforeEach
    void setUp() {
        when(clock.instant()).thenReturn(NOW);
        when(routing.calculateRoute(any(), any())).thenReturn(new RouteEstimate(
                new BigDecimal("5200"), new BigDecimal("840"), "OSRM", geometry()));
    }

    @Test
    void quoteAndBookingReadTheSameStoredStreetGeometryWithoutReroutingOrRepricing() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        JsonNode created = createQuote(customer);
        UUID quoteId = UUID.fromString(created.path("quotePublicId").asText());
        BigDecimal originalFare = created.path("finalFare").decimalValue();

        JsonNode quoteRoute = route(QUOTES + "/" + quoteId + "/route", customer);
        assertThat(quoteRoute.path("availability").asText()).isEqualTo("AVAILABLE");
        assertThat(quoteRoute.path("geometryFormat").asText()).isEqualTo("GEOJSON_LINESTRING");
        assertThat(quoteRoute.path("geometry").path("type").asText()).isEqualTo("LineString");
        assertThat(quoteRoute.path("geometry").path("coordinates").size()).isEqualTo(3);
        assertThat(quoteRoute.path("geometry").path("coordinates").path(0).path(0).decimalValue())
                .isEqualByComparingTo("105.8524");
        assertThat(quoteRoute.path("geometry").path("coordinates").path(0).path(1).decimalValue())
                .isEqualByComparingTo("21.0287");
        assertThat(quoteRoute.path("sourceQuotePublicId").asText()).isEqualTo(quoteId.toString());
        assertThat(quoteRoute.path("routingProvider").asText()).isEqualTo("OSRM");
        assertThat(quoteRoute.path("capturedAt").asText()).isEqualTo(NOW.toString());

        String key = UUID.randomUUID().toString();
        JsonNode bookingCreated = createBooking(customer, quoteId, key);
        UUID bookingId = UUID.fromString(bookingCreated.path("bookingPublicId").asText());
        assertThat(bookingCreated.path("finalFare").decimalValue()).isEqualByComparingTo(originalFare);
        JsonNode bookingRoute = route(BOOKINGS + "/" + bookingId + "/route", customer);
        assertThat(bookingRoute.path("availability").asText()).isEqualTo("AVAILABLE");
        assertThat(bookingRoute.path("bookingPublicId").asText()).isEqualTo(bookingId.toString());
        assertThat(bookingRoute.path("sourceQuotePublicId").asText()).isEqualTo(quoteId.toString());
        assertThat(bookingRoute.path("geometry")).isEqualTo(quoteRoute.path("geometry"));

        String stored = jdbc.queryForObject("SELECT route_geometry::text FROM quotes WHERE public_id=?",
                String.class, quoteId);
        assertThat(mapper.readTree(stored)).isEqualTo(quoteRoute.path("geometry"));
        assertThat(quotes.findByPublicIdAndCustomerPublicId(quoteId, customer.getPublicId())
                .orElseThrow().getFinalFare()).isEqualByComparingTo(originalFare);
        mvc.perform(post(BOOKINGS).header("Authorization", bearer(customer))
                        .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"quotePublicId\":\"" + quoteId + "\"}"))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.data.bookingPublicId").value(bookingId.toString()));
        route(BOOKINGS + "/" + bookingId + "/route", customer);
        assertThat(bookings.countByQuoteId(quotes.findByPublicIdAndCustomerPublicId(
                quoteId, customer.getPublicId()).orElseThrow().getId())).isEqualTo(1);
        when(clock.instant()).thenReturn(NOW.plusSeconds(60));
        assertThat(route(QUOTES + "/" + quoteId + "/route", customer).path("geometry"))
                .isEqualTo(quoteRoute.path("geometry"));
        verify(routing, times(1)).calculateRoute(any(), any());
    }

    @Test
    void realJwtOwnershipAndAssignmentGateRouteReads() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        User otherCustomer = user(UserRole.CUSTOMER);
        User assignedUser = user(UserRole.DRIVER);
        User otherDriver = user(UserRole.DRIVER);
        UUID quoteId = UUID.fromString(createQuote(customer).path("quotePublicId").asText());
        UUID bookingId = UUID.fromString(createBooking(customer, quoteId, UUID.randomUUID().toString())
                .path("bookingPublicId").asText());
        String quotePath = QUOTES + "/" + quoteId + "/route";
        String bookingPath = BOOKINGS + "/" + bookingId + "/route";

        mvc.perform(get(quotePath)).andExpect(status().isUnauthorized());
        mvc.perform(get(quotePath).header("Authorization", bearer(otherCustomer)))
                .andExpect(status().isNotFound()).andExpect(jsonPath("$.code").value("QUOTE_NOT_FOUND"));
        mvc.perform(get(quotePath).header("Authorization", bearer(assignedUser)))
                .andExpect(status().isForbidden());
        mvc.perform(get(bookingPath)).andExpect(status().isUnauthorized());
        mvc.perform(get(bookingPath).header("Authorization", bearer(otherCustomer)))
                .andExpect(status().isNotFound()).andExpect(jsonPath("$.code").value("BOOKING_NOT_FOUND"));
        mvc.perform(get(bookingPath).header("Authorization", bearer(assignedUser)))
                .andExpect(status().isNotFound()).andExpect(jsonPath("$.code").value("BOOKING_NOT_FOUND"));

        Driver assigned = driver(assignedUser);
        Vehicle vehicle = vehicle(assigned);
        Long bookingPk = bookings.findOwned(bookingId, customer.getPublicId()).orElseThrow().getId();
        jdbc.update("""
                INSERT INTO booking_driver_offers
                    (public_id, booking_id, driver_id, vehicle_id, status, offered_at, expires_at)
                VALUES (?, ?, ?, ?, 'PENDING', ?, ?)
                """, UUID.randomUUID(), bookingPk, assigned.getId(), vehicle.getId(),
                Timestamp.from(NOW), Timestamp.from(NOW.plusSeconds(15)));
        mvc.perform(get(bookingPath).header("Authorization", bearer(assignedUser)))
                .andExpect(status().isNotFound()).andExpect(jsonPath("$.code").value("BOOKING_NOT_FOUND"));

        jdbc.update("""
                UPDATE bookings SET status='DRIVER_ACCEPTED', assigned_driver_id=?, assigned_vehicle_id=?,
                    driver_accepted_at=?, version=version+1 WHERE id=?
                """, assigned.getId(), vehicle.getId(), Timestamp.from(NOW), bookingPk);
        route(bookingPath, assignedUser);
        mvc.perform(get(bookingPath).header("Authorization", bearer(otherDriver)))
                .andExpect(status().isNotFound()).andExpect(jsonPath("$.code").value("BOOKING_NOT_FOUND"));
        route(bookingPath, customer);
        jdbc.update("""
                UPDATE bookings SET status='COMPLETED', driver_arrived_at=?, passenger_onboard_at=?,
                    trip_started_at=?, trip_completed_at=?, version=version+1 WHERE id=?
                """, Timestamp.from(NOW.plusSeconds(1)), Timestamp.from(NOW.plusSeconds(2)),
                Timestamp.from(NOW.plusSeconds(3)), Timestamp.from(NOW.plusSeconds(4)), bookingPk);
        assertThat(route(bookingPath, assignedUser).path("geometry").path("coordinates").size()).isEqualTo(3);
        assertThat(route(bookingPath, customer).path("geometry").path("coordinates").size()).isEqualTo(3);
        verify(routing, times(1)).calculateRoute(any(), any());
    }

    @Test
    void preMigrationQuoteHasExplicitUnavailableRouteAfterExpiryAndBookingCreation() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        GeoCoordinate pickup = new GeoCoordinate(new BigDecimal("21.0287"), new BigDecimal("105.8524"));
        GeoCoordinate dropoff = new GeoCoordinate(new BigDecimal("21.0245"), new BigDecimal("105.8576"));
        RouteEstimate oldRoute = new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "OSRM");
        Quote quote = quotes.saveAndFlush(new Quote(customer, pickup, dropoff,
                VehicleType.MOTORBIKE, oldRoute, pricing.calculate(VehicleType.MOTORBIKE, oldRoute), NOW));
        assertThat(jdbc.queryForObject("SELECT route_geometry IS NULL FROM quotes WHERE id=?",
                Boolean.class, quote.getId())).isTrue();

        JsonNode unavailable = route(QUOTES + "/" + quote.getPublicId() + "/route", customer);
        assertThat(unavailable.path("availability").asText()).isEqualTo("UNAVAILABLE");
        assertThat(unavailable.path("geometry").isNull()).isTrue();
        JsonNode created = createBooking(customer, quote.getPublicId(), UUID.randomUUID().toString());
        when(clock.instant()).thenReturn(NOW.plusSeconds(60));
        JsonNode afterExpiry = route(QUOTES + "/" + quote.getPublicId() + "/route", customer);
        JsonNode booked = route(BOOKINGS + "/" + created.path("bookingPublicId").asText() + "/route", customer);
        assertThat(afterExpiry.path("availability").asText()).isEqualTo("UNAVAILABLE");
        assertThat(booked.path("availability").asText()).isEqualTo("UNAVAILABLE");
        assertThat(booked.path("geometry").isNull()).isTrue();
        verifyNoInteractions(routing);
    }

    @Test
    void storedRouteIsImmutableEvenWhenQuoteIsConsumed() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        UUID quoteId = UUID.fromString(createQuote(customer).path("quotePublicId").asText());
        String before = jdbc.queryForObject("SELECT route_geometry::text FROM quotes WHERE public_id=?",
                String.class, quoteId);
        createBooking(customer, quoteId, UUID.randomUUID().toString());
        assertThat(jdbc.queryForObject("SELECT route_geometry::text FROM quotes WHERE public_id=?",
                String.class, quoteId)).isEqualTo(before);
        assertThatThrownBy(() -> jdbc.update("UPDATE quotes SET route_geometry = NULL WHERE public_id=?", quoteId))
                .isInstanceOf(DataAccessException.class);
        assertThat(jdbc.queryForObject("SELECT route_geometry::text FROM quotes WHERE public_id=?",
                String.class, quoteId)).isEqualTo(before);
    }

    private JsonNode createQuote(User customer) throws Exception {
        return mapper.readTree(mvc.perform(post(QUOTES).header("Authorization", bearer(customer))
                        .contentType(MediaType.APPLICATION_JSON).content(QUOTE_REQUEST))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).path("data");
    }

    private JsonNode createBooking(User customer, UUID quoteId, String key) throws Exception {
        return mapper.readTree(mvc.perform(post(BOOKINGS).header("Authorization", bearer(customer))
                        .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"quotePublicId\":\"" + quoteId + "\"}"))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).path("data");
    }

    private JsonNode route(String path, User user) throws Exception {
        return mapper.readTree(mvc.perform(get(path).header("Authorization", bearer(user)))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString()).path("data");
    }

    private User user(UserRole role) {
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "route-" + UUID.randomUUID() + "@example.test", "hash", "Route Test");
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private Driver driver(User user) {
        Driver driver = new Driver(user, "ROUTE-" + UUID.randomUUID());
        driver.setApprovalStatus(DriverApprovalStatus.APPROVED);
        driver.setOperatingStatus(DriverOperatingStatus.ONLINE);
        return drivers.saveAndFlush(driver);
    }

    private Vehicle vehicle(Driver driver) {
        Vehicle vehicle = new Vehicle(driver, "R-" + UUID.randomUUID().toString().substring(0, 12),
                VehicleType.MOTORBIKE, "Test", "Test", "White");
        vehicle.setActive(true);
        return vehicles.saveAndFlush(vehicle);
    }

    private RouteGeometry geometry() {
        return new RouteGeometry("LineString", List.of(
                List.of(new BigDecimal("105.8524"), new BigDecimal("21.0287")),
                List.of(new BigDecimal("105.8550"), new BigDecimal("21.0260")),
                List.of(new BigDecimal("105.8576"), new BigDecimal("21.0245"))));
    }

    private String bearer(User user) { return "Bearer " + jwt.createAccessToken(user); }
}
