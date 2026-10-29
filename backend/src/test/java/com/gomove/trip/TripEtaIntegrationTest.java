package com.gomove.trip;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.auth.domain.UserRole;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.booking.domain.Booking;
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
import com.gomove.pricing.engine.PricingEngine;
import com.gomove.pricing.routing.RoutingService;
import com.gomove.vehicle.domain.Vehicle;
import com.gomove.vehicle.domain.VehicleRepository;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Clock;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@AutoConfigureMockMvc
class TripEtaIntegrationTest extends BaseIntegrationTest {
    private static final Instant NOW = Instant.parse("2026-10-28T03:00:00Z");
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired UserRepository users;
    @Autowired DriverRepository drivers;
    @Autowired VehicleRepository vehicles;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired PricingEngine pricing;
    @Autowired JwtTokenProvider jwt;
    @Autowired JdbcTemplate jdbc;
    @MockitoBean RoutingService routing;
    @MockitoBean Clock clock;

    @BeforeEach
    void setUp() {
        when(clock.instant()).thenReturn(NOW);
        when(routing.calculateTravelMetrics(any(), any())).thenReturn(
                new RouteEstimate(new BigDecimal("754.3"), new BigDecimal("123.5"), "OSRM"));
    }

    @Test
    void realJwtOwnershipAndPostgresGpsGateTransientPickupEta() throws Exception {
        Ride ride = ride();
        User stranger = user(UserRole.CUSTOMER);
        User admin = user(UserRole.ADMIN);
        User otherDriver = user(UserRole.DRIVER);
        String path = etaPath(ride);

        mvc.perform(get(path)).andExpect(status().isUnauthorized());
        mvc.perform(get(path).header("Authorization", bearer(admin))).andExpect(status().isForbidden());
        mvc.perform(get(path).header("Authorization", bearer(stranger)))
                .andExpect(status().isNotFound()).andExpect(jsonPath("$.code").value("BOOKING_NOT_FOUND"));
        mvc.perform(get(path).header("Authorization", bearer(otherDriver)))
                .andExpect(status().isNotFound()).andExpect(jsonPath("$.code").value("BOOKING_NOT_FOUND"));
        mvc.perform(get(path).header("Authorization", bearer(ride.customer())))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.phase").value("PICKUP"))
                .andExpect(jsonPath("$.data.reason").value("GPS_UNAVAILABLE"));
        verifyNoInteractions(routing);

        location(ride, 21.0287, 105.8524, 8.0, NOW);
        JsonNode owner = eta(path, ride.customer());
        assertThat(owner.path("status").asText()).isEqualTo("DRIVER_ACCEPTED");
        assertThat(owner.path("phase").asText()).isEqualTo("PICKUP");
        assertThat(owner.path("availability").asText()).isEqualTo("AVAILABLE");
        assertThat(owner.path("distanceMeters").decimalValue()).isEqualByComparingTo("754.300");
        assertThat(owner.path("durationSeconds").decimalValue()).isEqualByComparingTo("123.500");
        assertThat(owner.path("calculatedAt").asText()).isEqualTo(NOW.toString());
        assertThat(owner.path("locationUpdatedAt").asText()).isEqualTo(NOW.toString());
        assertThat(owner.path("expiresAt").asText()).isEqualTo(NOW.plusSeconds(30).toString());
        assertThat(owner.path("servedAt").asText()).isEqualTo(NOW.toString());
        assertThat(owner.has("latitude")).isFalse();
        assertThat(owner.has("longitude")).isFalse();
        assertThat(eta(path, ride.driver().getUser()).path("availability").asText()).isEqualTo("AVAILABLE");
        verify(routing, times(1)).calculateTravelMetrics(any(), any());
    }

    @Test
    void gpsQualityTripProgressAndCompletionChangeEtaWithoutChangingFinancialState() throws Exception {
        Ride ride = ride();
        String path = etaPath(ride);
        Map<String, Object> bookingBefore = jdbc.queryForMap("""
                SELECT status, final_fare, pricing_snapshot::text AS pricing_snapshot,
                       version, updated_at FROM bookings WHERE id=?
                """, ride.booking().getId());
        Map<String, Object> quoteBefore = jdbc.queryForMap("""
                SELECT final_fare, pricing_snapshot::text AS pricing_snapshot,
                       version, updated_at FROM quotes WHERE id=?
                """, ride.quote().getId());
        Integer cashBefore = jdbc.queryForObject("SELECT COUNT(*) FROM cash_payments WHERE booking_id=?",
                Integer.class, ride.booking().getId());

        location(ride, 21.0287, 105.8524, 101.0, NOW);
        assertThat(eta(path, ride.customer()).path("reason").asText()).isEqualTo("GPS_INACCURATE");
        location(ride, 21.0287, 105.8524, 8.0, NOW.minusSeconds(31));
        assertThat(eta(path, ride.customer()).path("reason").asText()).isEqualTo("GPS_STALE");
        verifyNoInteractions(routing);

        location(ride, 21.0287, 105.8524, 8.0, NOW);
        assertThat(eta(path, ride.customer()).path("availability").asText()).isEqualTo("AVAILABLE");
        assertThat(jdbc.queryForMap("""
                SELECT status, final_fare, pricing_snapshot::text AS pricing_snapshot,
                       version, updated_at FROM bookings WHERE id=?
                """, ride.booking().getId())).isEqualTo(bookingBefore);
        assertThat(jdbc.queryForMap("""
                SELECT final_fare, pricing_snapshot::text AS pricing_snapshot,
                       version, updated_at FROM quotes WHERE id=?
                """, ride.quote().getId())).isEqualTo(quoteBefore);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM cash_payments WHERE booking_id=?",
                Integer.class, ride.booking().getId())).isEqualTo(cashBefore);

        jdbc.update("""
                UPDATE bookings SET status='IN_PROGRESS', driver_arrived_at=?, passenger_onboard_at=?,
                    trip_started_at=?, version=version+1 WHERE id=?
                """, Timestamp.from(NOW.plusSeconds(1)), Timestamp.from(NOW.plusSeconds(2)),
                Timestamp.from(NOW.plusSeconds(3)), ride.booking().getId());
        when(clock.instant()).thenReturn(NOW.plusSeconds(4));
        location(ride, 21.0270, 105.8540, 8.0, NOW.plusSeconds(4));
        JsonNode destination = eta(path, ride.customer());
        assertThat(destination.path("status").asText()).isEqualTo("IN_PROGRESS");
        assertThat(destination.path("phase").asText()).isEqualTo("DESTINATION");
        assertThat(destination.path("availability").asText()).isEqualTo("AVAILABLE");
        verify(routing, times(2)).calculateTravelMetrics(any(), any());

        jdbc.update("""
                UPDATE bookings SET status='COMPLETED', trip_completed_at=?, version=version+1 WHERE id=?
                """, Timestamp.from(NOW.plusSeconds(5)), ride.booking().getId());
        when(clock.instant()).thenReturn(NOW.plusSeconds(6));
        JsonNode completed = eta(path, ride.customer());
        assertThat(completed.path("status").asText()).isEqualTo("COMPLETED");
        assertThat(completed.path("availability").asText()).isEqualTo("UNAVAILABLE");
        assertThat(completed.path("reason").asText()).isEqualTo("NOT_APPLICABLE");
        assertThat(completed.path("distanceMeters").isNull()).isTrue();
        assertThat(completed.path("locationUpdatedAt").isNull()).isTrue();
        verify(routing, times(2)).calculateTravelMetrics(any(), any());
        assertThat(jdbc.queryForObject("SELECT final_fare FROM bookings WHERE id=?",
                BigDecimal.class, ride.booking().getId())).isEqualByComparingTo(ride.booking().getFinalFare());
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM cash_payments WHERE booking_id=?",
                Integer.class, ride.booking().getId())).isEqualTo(cashBefore);
    }

    private Ride ride() {
        User customer = user(UserRole.CUSTOMER);
        GeoCoordinate pickup = new GeoCoordinate(new BigDecimal("21.0300"), new BigDecimal("105.8500"));
        GeoCoordinate dropoff = new GeoCoordinate(new BigDecimal("21.0245"), new BigDecimal("105.8576"));
        RouteEstimate route = new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "OSRM");
        Quote quote = new Quote(customer, pickup, dropoff, VehicleType.MOTORBIKE, route,
                pricing.calculate(VehicleType.MOTORBIKE, route), NOW.minusSeconds(1));
        quote.consume(NOW);
        quote = quotes.saveAndFlush(quote);
        Booking booking = bookings.saveAndFlush(new Booking(customer, quote));
        User driverUser = user(UserRole.DRIVER);
        Driver driver = new Driver(driverUser, "ETA-" + UUID.randomUUID());
        driver.setApprovalStatus(DriverApprovalStatus.APPROVED);
        driver.setOperatingStatus(DriverOperatingStatus.BUSY);
        driver = drivers.saveAndFlush(driver);
        Vehicle vehicle = new Vehicle(driver, "ETA-" + UUID.randomUUID().toString().substring(0, 12),
                VehicleType.MOTORBIKE, "Test", "Test", "Blue");
        vehicle.setActive(true);
        vehicle = vehicles.saveAndFlush(vehicle);
        jdbc.update("""
                UPDATE bookings SET status='DRIVER_ACCEPTED', assigned_driver_id=?, assigned_vehicle_id=?,
                    driver_accepted_at=?, version=version+1 WHERE id=?
                """, driver.getId(), vehicle.getId(), Timestamp.from(NOW), booking.getId());
        return new Ride(customer, quote, booking, driver);
    }

    private void location(Ride ride, double latitude, double longitude, Double accuracy, Instant at) {
        jdbc.update("""
                INSERT INTO driver_locations (driver_id, current_location, accuracy, updated_at, version)
                VALUES (?, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?, ?, 0)
                ON CONFLICT (driver_id) DO UPDATE SET current_location=EXCLUDED.current_location,
                    accuracy=EXCLUDED.accuracy, updated_at=EXCLUDED.updated_at,
                    version=driver_locations.version+1
                """, ride.driver().getId(), longitude, latitude, accuracy, Timestamp.from(at));
    }

    private JsonNode eta(String path, User user) throws Exception {
        return mapper.readTree(mvc.perform(get(path).header("Authorization", bearer(user)))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString()).path("data");
    }

    private String etaPath(Ride ride) {
        return "/api/v1/bookings/" + ride.booking().getPublicId() + "/eta";
    }

    private User user(UserRole role) {
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "eta-" + UUID.randomUUID() + "@example.test", "hash", "ETA Test");
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private String bearer(User user) { return "Bearer " + jwt.createAccessToken(user); }

    private record Ride(User customer, Quote quote, Booking booking, Driver driver) {}
}
