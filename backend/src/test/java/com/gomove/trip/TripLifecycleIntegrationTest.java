package com.gomove.trip;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.auth.domain.UserRole;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.booking.domain.Booking;
import com.gomove.booking.domain.BookingRepository;
import com.gomove.booking.domain.BookingStatus;
import com.gomove.booking.service.BookingApplicationService;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.common.exception.DomainException;
import com.gomove.dispatch.infrastructure.DispatchStore;
import com.gomove.driver.domain.Driver;
import com.gomove.driver.domain.DriverApprovalStatus;
import com.gomove.driver.domain.DriverOperatingStatus;
import com.gomove.driver.domain.DriverRepository;
import com.gomove.driver.service.DriverService;
import com.gomove.location.api.UpdateDriverLocationRequest;
import com.gomove.location.service.DriverLocationService;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.Quote;
import com.gomove.pricing.domain.QuoteRepository;
import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.engine.PricingEngine;
import com.gomove.trip.service.TripAction;
import com.gomove.trip.service.TripApplicationService;
import com.gomove.vehicle.domain.Vehicle;
import com.gomove.vehicle.domain.VehicleRepository;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@AutoConfigureMockMvc
class TripLifecycleIntegrationTest extends BaseIntegrationTest {
    @Autowired UserRepository users;
    @Autowired DriverRepository drivers;
    @Autowired VehicleRepository vehicles;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired BookingApplicationService bookingService;
    @Autowired PricingEngine pricing;
    @Autowired TripApplicationService trips;
    @Autowired DispatchStore dispatch;
    @Autowired DriverService driverService;
    @Autowired DriverLocationService driverLocations;
    @Autowired JdbcTemplate jdbc;
    @Autowired MockMvc mvc;
    @Autowired JwtTokenProvider jwt;
    @Autowired ObjectMapper mapper;

    @Test
    void sequentialTransitionsPreserveFareAssignmentAndBusyDriver() throws Exception {
        Ride ride = ride();
        String originalSnapshot = jdbc.queryForObject("SELECT pricing_snapshot::text FROM bookings WHERE id=?",
                String.class, ride.booking().getId());
        BigDecimal originalFare = ride.booking().getFinalFare();

        mvc.perform(post(actionUrl(ride, "start")).header("Authorization", bearer(ride.driver().getUser())))
                .andExpect(status().isConflict());
        for (String action : new String[]{"arrive", "onboard", "start", "complete"}) {
            mvc.perform(post(actionUrl(ride, action)).header("Authorization", bearer(ride.driver().getUser())))
                    .andExpect(status().isOk())
                    .andExpect(jsonPath("$.data.bookingPublicId").value(ride.booking().getPublicId().toString()));
            mvc.perform(post(actionUrl(ride, action)).header("Authorization", bearer(ride.driver().getUser())))
                    .andExpect(status().isConflict());
            assertThat(drivers.findById(ride.driver().getId()).orElseThrow().getOperatingStatus())
                    .isEqualTo(DriverOperatingStatus.BUSY);
            assertThat(dispatch.hasActiveAssignment(ride.driver().getId())).isTrue();
        }
        Booking completed = bookings.findById(ride.booking().getId()).orElseThrow();
        assertThat(completed.getStatus()).isEqualTo(BookingStatus.COMPLETED);
        assertThat(completed.getDriverArrivedAt()).isNotNull();
        assertThat(completed.getPassengerOnboardAt()).isNotNull();
        assertThat(completed.getTripStartedAt()).isNotNull();
        assertThat(completed.getTripCompletedAt()).isNotNull();
        assertThat(completed.getDriverAcceptedAt()).isBeforeOrEqualTo(completed.getDriverArrivedAt());
        assertThat(completed.getDriverArrivedAt()).isBeforeOrEqualTo(completed.getPassengerOnboardAt());
        assertThat(completed.getPassengerOnboardAt()).isBeforeOrEqualTo(completed.getTripStartedAt());
        assertThat(completed.getTripStartedAt()).isBeforeOrEqualTo(completed.getTripCompletedAt());
        assertThat(completed.getDriverReleasedAt()).isNull();
        assertThat(completed.getAssignedDriver().getId()).isEqualTo(ride.driver().getId());
        assertThat(completed.getAssignedVehicle().getId()).isEqualTo(ride.vehicle().getId());
        assertThat(completed.getFinalFare()).isEqualByComparingTo(originalFare);
        assertThat(jdbc.queryForObject("SELECT pricing_snapshot::text FROM bookings WHERE id=?",
                String.class, ride.booking().getId())).isEqualTo(originalSnapshot);
        assertThatThrownBy(() -> driverService.setOwnOperatingStatus(ride.driver().getUser().getPublicId(),
                UserRole.DRIVER, DriverOperatingStatus.ONLINE)).isInstanceOf(DomainException.class)
                .extracting(ex -> ((DomainException) ex).getCode()).isEqualTo("DRIVER_HAS_UNRELEASED_BOOKING");
        assertThatThrownBy(() -> driverService.updateApprovalStatusAsAdmin(UserRole.ADMIN,
                ride.driver().getPublicId(), DriverApprovalStatus.SUSPENDED))
                .isInstanceOf(DomainException.class)
                .extracting(ex -> ((DomainException) ex).getCode()).isEqualTo("DRIVER_HAS_UNRELEASED_BOOKING");
        assertThat(drivers.findById(ride.driver().getId()).orElseThrow().getOperatingStatus())
                .isEqualTo(DriverOperatingStatus.BUSY);
        mvc.perform(get("/api/v1/bookings/" + ride.booking().getPublicId())
                .header("Authorization", bearer(ride.customer())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.status").value("COMPLETED"))
                .andExpect(jsonPath("$.data.tripCompletedAt").exists())
                .andExpect(jsonPath("$.data.finalFare").value(originalFare.doubleValue()));

        JsonNode replay = mapper.readTree(bookingService.create(ride.customer().getPublicId(), UserRole.CUSTOMER,
                ride.quote().getPublicId(), ride.key()).responseBody());
        assertThat(replay.path("data").path("status").asText()).isEqualTo("REQUESTED");
    }

    @Test
    void ownershipSecurityTrackingAndPostGisRecovery() throws Exception {
        Ride ride = ride();
        User stranger = user(UserRole.CUSTOMER);
        Driver other = driver();
        mvc.perform(post(actionUrl(ride, "arrive"))).andExpect(status().isUnauthorized());
        mvc.perform(post(actionUrl(ride, "arrive")).header("Authorization", bearer(ride.customer())))
                .andExpect(status().isForbidden());
        mvc.perform(post(actionUrl(ride, "arrive")).header("Authorization", bearer(other.getUser())))
                .andExpect(status().isNotFound());
        String tracking = "/api/v1/bookings/" + ride.booking().getPublicId() + "/tracking";
        mvc.perform(get(tracking).header("Authorization", bearer(stranger))).andExpect(status().isNotFound());
        mvc.perform(get(tracking).header("Authorization", bearer(other.getUser()))).andExpect(status().isNotFound());
        mvc.perform(get(tracking).header("Authorization", bearer(ride.customer())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.latitude").value(org.hamcrest.Matchers.nullValue()));

        trips.updateRideLocation(ride.booking().getPublicId(), ride.driver().getUser().getPublicId(),
                UserRole.DRIVER, new UpdateDriverLocationRequest(21.0287, 105.8524, 8.5, 120.0));
        mvc.perform(get(tracking).header("Authorization", bearer(ride.customer())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.latitude").value(21.0287))
                .andExpect(jsonPath("$.data.longitude").value(105.8524))
                .andExpect(jsonPath("$.data.locationUpdatedAt").exists());
        mvc.perform(get(tracking).header("Authorization", bearer(ride.driver().getUser())))
                .andExpect(status().isOk());
        assertThat(jdbc.queryForObject("SELECT ST_SRID(current_location::geometry) FROM driver_locations WHERE driver_id=?",
                Integer.class, ride.driver().getId())).isEqualTo(4326);
        assertThatThrownBy(() -> trips.updateRideLocation(ride.booking().getPublicId(),
                ride.driver().getUser().getPublicId(), UserRole.DRIVER,
                new UpdateDriverLocationRequest(Double.NaN, 105.0, null, null)))
                .isInstanceOf(DomainException.class);
        for (TripAction action : TripAction.values()) {
            trips.transition(ride.booking().getPublicId(), ride.driver().getUser().getPublicId(),
                    UserRole.DRIVER, action);
        }
        mvc.perform(get(tracking).header("Authorization", bearer(ride.customer())))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.status").value("COMPLETED"))
                .andExpect(jsonPath("$.data.driverPublicId").value(ride.driver().getPublicId().toString()))
                .andExpect(jsonPath("$.data.driverAcceptedAt").exists())
                .andExpect(jsonPath("$.data.tripCompletedAt").exists())
                .andExpect(jsonPath("$.data.latitude").value(org.hamcrest.Matchers.nullValue()))
                .andExpect(jsonPath("$.data.longitude").value(org.hamcrest.Matchers.nullValue()))
                .andExpect(jsonPath("$.data.accuracy").value(org.hamcrest.Matchers.nullValue()))
                .andExpect(jsonPath("$.data.bearing").value(org.hamcrest.Matchers.nullValue()))
                .andExpect(jsonPath("$.data.locationUpdatedAt").value(org.hamcrest.Matchers.nullValue()));
        driverLocations.updateOwnLocation(ride.driver().getUser().getPublicId(), UserRole.DRIVER,
                22.1234, 106.5678, 3.0, 90.0);
        assertThat(jdbc.queryForObject("SELECT ST_Y(current_location::geometry) FROM driver_locations WHERE driver_id=?",
                Double.class, ride.driver().getId())).isEqualTo(22.1234);
        mvc.perform(get(tracking).header("Authorization", bearer(ride.customer())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.status").value("COMPLETED"))
                .andExpect(jsonPath("$.data.tripCompletedAt").exists())
                .andExpect(jsonPath("$.data.latitude").value(org.hamcrest.Matchers.nullValue()))
                .andExpect(jsonPath("$.data.longitude").value(org.hamcrest.Matchers.nullValue()))
                .andExpect(jsonPath("$.data.accuracy").value(org.hamcrest.Matchers.nullValue()))
                .andExpect(jsonPath("$.data.bearing").value(org.hamcrest.Matchers.nullValue()))
                .andExpect(jsonPath("$.data.locationUpdatedAt").value(org.hamcrest.Matchers.nullValue()));
        mvc.perform(get(tracking).header("Authorization", bearer(stranger))).andExpect(status().isNotFound());
        assertThatThrownBy(() -> trips.updateRideLocation(ride.booking().getPublicId(),
                ride.driver().getUser().getPublicId(), UserRole.DRIVER,
                new UpdateDriverLocationRequest(21.0, 105.0, null, null)))
                .isInstanceOf(DomainException.class)
                .extracting(ex -> ((DomainException) ex).getCode()).isEqualTo("TRIP_TRACKING_CLOSED");
    }

    @Test
    void migrationAndUnreleasedUniquenessCoverCompletedTrips() {
        Ride ride = ride();
        assertThat(jdbc.queryForObject("SELECT version FROM flyway_schema_history WHERE success=TRUE ORDER BY installed_rank DESC LIMIT 1",
                String.class)).isEqualTo("12");
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM pg_constraint WHERE conname IN ('chk_bookings_trip_status','chk_bookings_trip_timestamps','chk_bookings_assignment_state')",
                Integer.class)).isEqualTo(3);
        assertThatThrownBy(() -> jdbc.update("UPDATE bookings SET status='COMPLETED' WHERE id=?", ride.booking().getId()))
                .isInstanceOf(DataIntegrityViolationException.class);
        assertThatThrownBy(() -> jdbc.update("UPDATE bookings SET status='UNKNOWN' WHERE id=?", ride.booking().getId()))
                .isInstanceOf(DataIntegrityViolationException.class);
        for (TripAction action : TripAction.values()) {
            trips.transition(ride.booking().getPublicId(), ride.driver().getUser().getPublicId(),
                    UserRole.DRIVER, action);
        }
        Ride second = unassignedRide();
        // Simulate a stale ONLINE flag: candidate selection must still exclude an
        // unreleased driver, even after the first trip has COMPLETED.
        jdbc.update("UPDATE drivers SET operating_status='ONLINE', version=version+1 WHERE id=?",
                ride.driver().getId());
        jdbc.update("UPDATE bookings SET status='SEARCHING_DRIVER', version=version+1 WHERE id=?",
                second.booking().getId());
        jdbc.update("""
                INSERT INTO driver_locations (driver_id, current_location, updated_at, version)
                VALUES (?, ST_SetSRID(ST_MakePoint(105.8524, 21.0287), 4326)::geography, ?, 0)
                """, ride.driver().getId(), Timestamp.from(Instant.now()));
        assertThat(dispatch.nearestCandidate(second.booking().getId(), Instant.now().minusSeconds(30), 5000))
                .isEmpty();
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE bookings SET status='DRIVER_ACCEPTED', assigned_driver_id=?, assigned_vehicle_id=?,
                    driver_accepted_at=?, version=version+1 WHERE id=?
                """, ride.driver().getId(), ride.vehicle().getId(), Timestamp.from(Instant.now()),
                second.booking().getId())).isInstanceOf(DataIntegrityViolationException.class);
        assertThat(dispatch.hasActiveAssignment(ride.driver().getId())).isTrue();
    }

    @Test
    void concurrentArriveOnlyOneCommit() throws Exception {
        Ride ride = ride();
        var pool = Executors.newFixedThreadPool(2);
        var ready = new CountDownLatch(2);
        var start = new CountDownLatch(1);
        Callable<String> command = () -> {
            ready.countDown();
            start.await();
            try {
                trips.transition(ride.booking().getPublicId(), ride.driver().getUser().getPublicId(),
                        UserRole.DRIVER, TripAction.ARRIVE);
                return "OK";
            } catch (DomainException ex) { return ex.getCode(); }
        };
        try {
            var first = pool.submit(command);
            var second = pool.submit(command);
            assertThat(ready.await(5, TimeUnit.SECONDS)).isTrue();
            start.countDown();
            assertThat(java.util.List.of(first.get(10, TimeUnit.SECONDS), second.get(10, TimeUnit.SECONDS)))
                    .containsExactlyInAnyOrder("OK", "TRIP_INVALID_STATE");
        } finally { pool.shutdownNow(); }
        assertThat(bookings.findById(ride.booking().getId()).orElseThrow().getStatus())
                .isEqualTo(BookingStatus.DRIVER_ARRIVED);
    }

    private Ride ride() { return assign(unassignedRide()); }

    private Ride unassignedRide() {
        User customer = user(UserRole.CUSTOMER);
        Quote quote = quotes.saveAndFlush(new Quote(customer,
                new GeoCoordinate(new BigDecimal("21.0287"), new BigDecimal("105.8524")),
                new GeoCoordinate(new BigDecimal("21.0245"), new BigDecimal("105.8576")),
                VehicleType.MOTORBIKE,
                new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "TEST_ROUTER"),
                pricing.calculate(VehicleType.MOTORBIKE,
                        new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "TEST_ROUTER")),
                Instant.now()));
        String key = UUID.randomUUID().toString();
        try {
            JsonNode data = mapper.readTree(bookingService.create(customer.getPublicId(), UserRole.CUSTOMER,
                    quote.getPublicId(), key).responseBody()).path("data");
            Booking booking = bookings.findOwned(UUID.fromString(data.path("bookingPublicId").asText()),
                    customer.getPublicId()).orElseThrow();
            return new Ride(customer, quote, booking, key, null, null);
        } catch (Exception ex) { throw new IllegalStateException(ex); }
    }

    private Ride assign(Ride ride) {
        Driver driver = driver();
        Vehicle vehicle = new Vehicle(driver, "TRIP-" + UUID.randomUUID().toString().substring(0, 12),
                VehicleType.MOTORBIKE, "Test", "Test", "White");
        vehicle.setActive(true);
        vehicle = vehicles.saveAndFlush(vehicle);
        jdbc.update("""
                UPDATE bookings SET status='DRIVER_ACCEPTED', assigned_driver_id=?, assigned_vehicle_id=?,
                    driver_accepted_at=?, version=version+1 WHERE id=?
                """, driver.getId(), vehicle.getId(), Timestamp.from(Instant.now()), ride.booking().getId());
        return new Ride(ride.customer(), ride.quote(), bookings.findById(ride.booking().getId()).orElseThrow(),
                ride.key(), driver, vehicle);
    }

    private User user(UserRole role) {
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "trip-" + UUID.randomUUID() + "@example.test", "hash", "Trip Test");
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private Driver driver() {
        Driver driver = new Driver(user(UserRole.DRIVER), "TRIP-" + UUID.randomUUID());
        driver.setApprovalStatus(DriverApprovalStatus.APPROVED);
        driver.setOperatingStatus(DriverOperatingStatus.BUSY);
        return drivers.saveAndFlush(driver);
    }

    private String actionUrl(Ride ride, String action) {
        return "/api/v1/drivers/me/trips/" + ride.booking().getPublicId() + "/" + action;
    }

    private String bearer(User user) { return "Bearer " + jwt.createAccessToken(user); }

    private record Ride(User customer, Quote quote, Booking booking, String key,
                        Driver driver, Vehicle vehicle) {}
}
