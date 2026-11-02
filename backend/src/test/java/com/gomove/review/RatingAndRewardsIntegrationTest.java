package com.gomove.review;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.auth.domain.*;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.booking.domain.*;
import com.gomove.booking.service.BookingApplicationService;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.common.exception.DomainException;
import com.gomove.driver.domain.*;
import com.gomove.pricing.domain.*;
import com.gomove.pricing.engine.PricingEngine;
import com.gomove.review.api.RatingRequest;
import com.gomove.review.service.RatingService;
import com.gomove.vehicle.domain.*;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@AutoConfigureMockMvc
class RatingAndRewardsIntegrationTest extends BaseIntegrationTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired JwtTokenProvider jwt;
    @Autowired JdbcTemplate jdbc;
    @Autowired UserRepository users;
    @Autowired DriverRepository drivers;
    @Autowired VehicleRepository vehicles;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired BookingApplicationService bookingService;
    @Autowired PricingEngine pricing;
    @Autowired RatingService ratings;

    @Test void ownedCompletedRatingIsOptionalUniqueAndServerAttributed() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        User other = user(UserRole.CUSTOMER);
        Driver driver = driver();
        Vehicle vehicle = vehicle(driver);
        Booking active = booking(customer);
        Booking completed = completed(customer, driver, vehicle, true);
        String path = "/api/v1/bookings/" + completed.getPublicId() + "/rating";

        mvc.perform(get(path)).andExpect(status().isUnauthorized());
        mvc.perform(get(path).header("Authorization", bearer(driver.getUser())))
                .andExpect(status().isForbidden());
        mvc.perform(get(path).header("Authorization", bearer(other)))
                .andExpect(status().isNotFound());
        mvc.perform(get(path).header("Authorization", bearer(customer)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.rated").value(false));
        mvc.perform(post("/api/v1/bookings/" + active.getPublicId() + "/rating")
                .header("Authorization", bearer(customer)).contentType(MediaType.APPLICATION_JSON)
                .content("{\"stars\":5}"))
                .andExpect(status().isConflict()).andExpect(jsonPath("$.code").value("RATING_TRIP_NOT_COMPLETED"));
        mvc.perform(post(path).header("Authorization", bearer(other))
                .contentType(MediaType.APPLICATION_JSON).content("{\"stars\":5}"))
                .andExpect(status().isNotFound());
        mvc.perform(post(path).header("Authorization", bearer(customer))
                .contentType(MediaType.APPLICATION_JSON).content("{\"stars\":0}"))
                .andExpect(status().isBadRequest());
        mvc.perform(post(path).header("Authorization", bearer(customer))
                .contentType(MediaType.APPLICATION_JSON)
                .content(mapper.writeValueAsString(new RatingRequest(5, "x".repeat(501)))))
                .andExpect(status().isBadRequest());

        String body = mvc.perform(post(path).header("Authorization", bearer(customer))
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"stars\":5,\"comment\":\"  Chuyến đi tốt  \"}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.stars").value(5))
                .andExpect(jsonPath("$.data.comment").value("Chuyến đi tốt"))
                .andReturn().getResponse().getContentAsString();
        UUID ratingId = UUID.fromString(mapper.readTree(body).path("data").path("publicId").asText());
        mvc.perform(post(path).header("Authorization", bearer(customer))
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"stars\":5,\"comment\":\"Chuyến đi tốt\"}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.publicId").value(ratingId.toString()));
        mvc.perform(post(path).header("Authorization", bearer(customer))
                .contentType(MediaType.APPLICATION_JSON).content("{\"stars\":1}"))
                .andExpect(status().isConflict()).andExpect(jsonPath("$.code").value("RATING_ALREADY_SUBMITTED"));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM trip_ratings WHERE booking_id=?",
                Long.class, completed.getId())).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT points_delta FROM driver_point_events WHERE driver_id=?",
                Integer.class, driver.getId())).isEqualTo(10);
        mvc.perform(get("/api/v1/drivers/me/reputation")
                .header("Authorization", bearer(driver.getUser())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.ratingCount").value(1))
                .andExpect(jsonPath("$.data.ratingAverage").value(5.0))
                .andExpect(jsonPath("$.data.availablePoints").value(10));
        mvc.perform(get("/api/v1/drivers/me/rewards")
                .header("Authorization", bearer(driver.getUser())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.total").value(1))
                .andExpect(jsonPath("$.data.items[0].bookingPublicId").value(completed.getPublicId().toString()));
        mvc.perform(get("/api/v1/drivers/me/rewards")
                .header("Authorization", bearer(customer))).andExpect(status().isForbidden());
    }

    @Test void unratedDriverIsNotShownAsFiveStarsAndDeductionsNeverMakeDisplayedBalanceNegative() throws Exception {
        Driver driver = driver();
        Vehicle vehicle = vehicle(driver);
        User admin = user(UserRole.ADMIN);
        mvc.perform(get("/api/v1/drivers/me/reputation")
                .header("Authorization", bearer(driver.getUser())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.ratingAverage").isEmpty())
                .andExpect(jsonPath("$.data.ratingCount").value(0));
        mvc.perform(patch("/api/v1/drivers/" + driver.getPublicId() + "/approval-status")
                .header("Authorization", bearer(admin)).contentType(MediaType.APPLICATION_JSON)
                .content("{\"status\":\"APPROVED\"}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.ratingAverage").isEmpty())
                .andExpect(jsonPath("$.data.ratingCount").value(0));
        for (int stars : new int[]{1, 2, 3, 4, 5}) {
            User customer = user(UserRole.CUSTOMER);
            Booking booking = completed(customer, driver, vehicle, true);
            ratings.submit(booking.getPublicId(), customer.getPublicId(), UserRole.CUSTOMER,
                    new RatingRequest(stars, null));
        }
        mvc.perform(get("/api/v1/drivers/me/reputation")
                .header("Authorization", bearer(driver.getUser())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.ratingCount").value(5))
                .andExpect(jsonPath("$.data.ratingAverage").value(3.0))
                .andExpect(jsonPath("$.data.earnedPoints").value(15))
                .andExpect(jsonPath("$.data.deductedPoints").value(15))
                .andExpect(jsonPath("$.data.availablePoints").value(0));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM driver_point_events WHERE driver_id=?",
                Long.class, driver.getId())).isEqualTo(5);
        User extra = user(UserRole.CUSTOMER);
        Booking negative = completed(extra, driver, vehicle, true);
        ratings.submit(negative.getPublicId(), extra.getPublicId(), UserRole.CUSTOMER,
                new RatingRequest(1, null));
        mvc.perform(get("/api/v1/drivers/me/reputation")
                .header("Authorization", bearer(driver.getUser())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.availablePoints").value(0))
                .andExpect(jsonPath("$.data.deductedPoints").value(25));
    }

    @Test void concurrentEquivalentSubmissionsCreateOneRatingAndOnePointEvent() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        Driver driver = driver();
        Booking booking = completed(customer, driver, vehicle(driver), true);
        var pool = Executors.newFixedThreadPool(2);
        var ready = new CountDownLatch(2);
        var start = new CountDownLatch(1);
        try {
            var first = pool.submit(() -> {
                ready.countDown(); start.await();
                return ratings.submit(booking.getPublicId(), customer.getPublicId(), UserRole.CUSTOMER,
                        new RatingRequest(4, "Đúng giờ"));
            });
            var second = pool.submit(() -> {
                ready.countDown(); start.await();
                return ratings.submit(booking.getPublicId(), customer.getPublicId(), UserRole.CUSTOMER,
                        new RatingRequest(4, "Đúng giờ"));
            });
            assertThat(ready.await(5, TimeUnit.SECONDS)).isTrue();
            start.countDown();
            assertThat(first.get(10, TimeUnit.SECONDS).publicId())
                    .isEqualTo(second.get(10, TimeUnit.SECONDS).publicId());
        } finally { pool.shutdownNow(); }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM trip_ratings WHERE booking_id=?",
                Long.class, booking.getId())).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM driver_point_events WHERE driver_id=?",
                Long.class, driver.getId())).isEqualTo(1);
    }

    @Test void tenLowRatingsFlagOnceAndAdminModeratesWithDriverDispute() throws Exception {
        User admin = user(UserRole.ADMIN);
        Driver driver = driver();
        Driver unrelated = driver();
        Vehicle vehicle = vehicle(driver);
        for (int i = 0; i < 10; i++) {
            User customer = user(UserRole.CUSTOMER);
            Booking booking = completed(customer, driver, vehicle, true);
            ratings.submit(booking.getPublicId(), customer.getPublicId(), UserRole.CUSTOMER,
                    new RatingRequest(1, null));
        }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM driver_quality_cases WHERE driver_id=?",
                Long.class, driver.getId())).isEqualTo(1);
        String list = mvc.perform(get("/api/v1/admin/quality-cases").header("Authorization", bearer(admin)))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
        UUID caseId = UUID.fromString(mapper.readTree(list).path("data").path("items").get(0).path("publicId").asText());
        String path = "/api/v1/admin/quality-cases/" + caseId;
        mvc.perform(get(path)).andExpect(status().isUnauthorized());
        mvc.perform(get(path).header("Authorization", bearer(driver.getUser())))
                .andExpect(status().isForbidden());
        mvc.perform(get(path).header("Authorization", bearer(admin)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.qualityCase.driverDisplayName").value(driver.getUser().getFullName()))
                .andExpect(jsonPath("$.data.recentRatings.length()").value(10));
        mvc.perform(post(path + "/actions").header("Authorization", bearer(admin))
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"action\":\"WARN\",\"note\":\"Mời tài xế cải thiện dịch vụ\"}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.qualityCase.status").value("WARNED"));
        mvc.perform(post("/api/v1/drivers/me/quality-cases/" + caseId + "/dispute")
                .header("Authorization", bearer(unrelated.getUser()))
                .contentType(MediaType.APPLICATION_JSON).content("{\"reason\":\"Không phải chuyến của tôi\"}"))
                .andExpect(status().isNotFound());
        mvc.perform(post("/api/v1/drivers/me/quality-cases/" + caseId + "/dispute")
                .header("Authorization", bearer(driver.getUser()))
                .contentType(MediaType.APPLICATION_JSON).content("{\"reason\":\"Xin xem lại\"}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.status").value("DISPUTED"));

        Booking active = booking(user(UserRole.CUSTOMER));
        assign(active, driver, vehicle);
        mvc.perform(post(path + "/actions").header("Authorization", bearer(admin))
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"action\":\"SUSPEND\",\"note\":\"Chất lượng thấp lặp lại\"}"))
                .andExpect(status().isConflict()).andExpect(jsonPath("$.code").value("DRIVER_HAS_UNRELEASED_BOOKING"));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM driver_quality_case_actions WHERE case_id=(SELECT id FROM driver_quality_cases WHERE public_id=?)",
                Long.class, caseId)).isEqualTo(2);
        completeExisting(active, driver, vehicle, true);
        mvc.perform(post(path + "/actions").header("Authorization", bearer(admin))
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"action\":\"SUSPEND\",\"note\":\"Chất lượng thấp lặp lại\"}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.qualityCase.status").value("SUSPENDED"));
        assertThat(jdbc.queryForObject("SELECT approval_status FROM drivers WHERE id=?",
                String.class, driver.getId())).isEqualTo("SUSPENDED");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM driver_quality_case_actions WHERE case_id=(SELECT id FROM driver_quality_cases WHERE public_id=?)",
                Long.class, caseId)).isEqualTo(3);
        User later = user(UserRole.CUSTOMER);
        Booking oldCompleted = completed(later, driver, vehicle, true);
        ratings.submit(oldCompleted.getPublicId(), later.getPublicId(), UserRole.CUSTOMER,
                new RatingRequest(1, null));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM driver_quality_cases WHERE driver_id=?",
                Long.class, driver.getId())).isEqualTo(1);
        mvc.perform(get(path).header("Authorization", bearer(admin)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.recentRatings.length()").value(10));
    }

    @Test void concurrentDifferentTripsStillTriggerThresholdAndDismissalRequiresNewEvidence() throws Exception {
        User admin = user(UserRole.ADMIN);
        Driver driver = driver();
        Vehicle vehicle = vehicle(driver);
        for (int i = 0; i < 8; i++) {
            User customer = user(UserRole.CUSTOMER);
            Booking trip = completed(customer, driver, vehicle, true);
            ratings.submit(trip.getPublicId(), customer.getPublicId(), UserRole.CUSTOMER,
                    new RatingRequest(1, null));
        }
        User firstCustomer = user(UserRole.CUSTOMER);
        User secondCustomer = user(UserRole.CUSTOMER);
        Booking firstTrip = completed(firstCustomer, driver, vehicle, true);
        Booking secondTrip = completed(secondCustomer, driver, vehicle, true);
        var pool = Executors.newFixedThreadPool(2);
        var ready = new CountDownLatch(2);
        var start = new CountDownLatch(1);
        try {
            var first = pool.submit(() -> {
                ready.countDown(); start.await();
                return ratings.submit(firstTrip.getPublicId(), firstCustomer.getPublicId(),
                        UserRole.CUSTOMER, new RatingRequest(1, null));
            });
            var second = pool.submit(() -> {
                ready.countDown(); start.await();
                return ratings.submit(secondTrip.getPublicId(), secondCustomer.getPublicId(),
                        UserRole.CUSTOMER, new RatingRequest(1, null));
            });
            assertThat(ready.await(5, TimeUnit.SECONDS)).isTrue();
            start.countDown();
            assertThat(first.get(10, TimeUnit.SECONDS)).isNotNull();
            assertThat(second.get(10, TimeUnit.SECONDS)).isNotNull();
        } finally { pool.shutdownNow(); }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM driver_quality_cases WHERE driver_id=?",
                Long.class, driver.getId())).isEqualTo(1);
        UUID caseId = jdbc.queryForObject("SELECT public_id FROM driver_quality_cases WHERE driver_id=?",
                UUID.class, driver.getId());
        mvc.perform(post("/api/v1/admin/quality-cases/" + caseId + "/actions")
                .header("Authorization", bearer(admin)).contentType(MediaType.APPLICATION_JSON)
                .content("{\"action\":\"DISMISS\",\"note\":\"Đã xem xét hồ sơ\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.qualityCase.status").value("DISMISSED"));
        User extra = user(UserRole.CUSTOMER);
        Booking extraTrip = completed(extra, driver, vehicle, true);
        ratings.submit(extraTrip.getPublicId(), extra.getPublicId(), UserRole.CUSTOMER,
                new RatingRequest(1, null));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM driver_quality_cases WHERE driver_id=?",
                Long.class, driver.getId())).isEqualTo(1);
    }

    @Test void v18ConstraintsAndImmutableEventsArePresent() {
        assertThat(jdbc.queryForObject("SELECT success FROM flyway_schema_history WHERE version='18'",
                Boolean.class)).isTrue();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid='trip_ratings'::regclass AND NOT tgisinternal",
                Long.class)).isGreaterThanOrEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid='driver_point_events'::regclass AND NOT tgisinternal",
                Long.class)).isGreaterThanOrEqualTo(1);
    }

    private User user(UserRole role) {
        String code = UUID.randomUUID().toString().substring(0, 8);
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                code + "@example.test", "hash", "Review Test " + code);
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private Driver driver() {
        Driver driver = new Driver(user(UserRole.DRIVER), "REVIEW-" + UUID.randomUUID());
        driver.setApprovalStatus(DriverApprovalStatus.APPROVED);
        driver.setOperatingStatus(DriverOperatingStatus.OFFLINE);
        return drivers.saveAndFlush(driver);
    }

    private Vehicle vehicle(Driver driver) {
        Vehicle vehicle = new Vehicle(driver, "REV-" + UUID.randomUUID().toString().substring(0, 12),
                VehicleType.MOTORBIKE, "Honda", "Wave", "Blue");
        vehicle.setActive(true);
        return vehicles.saveAndFlush(vehicle);
    }

    private Booking booking(User customer) {
        var route = new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "TEST_ROUTER");
        Quote quote = quotes.saveAndFlush(new Quote(customer,
                new GeoCoordinate(new BigDecimal("21.0287"), new BigDecimal("105.8524")),
                new GeoCoordinate(new BigDecimal("21.0245"), new BigDecimal("105.8576")),
                VehicleType.MOTORBIKE, route, pricing.calculate(VehicleType.MOTORBIKE, route), Instant.now()));
        try {
            String body = bookingService.create(customer.getPublicId(), UserRole.CUSTOMER,
                    quote.getPublicId(), UUID.randomUUID().toString()).responseBody();
            UUID id = UUID.fromString(mapper.readTree(body).path("data").path("bookingPublicId").asText());
            return bookings.findOwned(id, customer.getPublicId()).orElseThrow();
        } catch (Exception ex) { throw new IllegalStateException(ex); }
    }

    private Booking completed(User customer, Driver driver, Vehicle vehicle, boolean release) {
        Booking booking = booking(customer);
        completeExisting(booking, driver, vehicle, release);
        return booking;
    }

    private void assign(Booking booking, Driver driver, Vehicle vehicle) {
        jdbc.update("""
                UPDATE bookings SET status='DRIVER_ACCEPTED', assigned_driver_id=?, assigned_vehicle_id=?,
                    driver_accepted_at=CURRENT_TIMESTAMP, version=version+1 WHERE id=?
                """, driver.getId(), vehicle.getId(), booking.getId());
    }

    private void completeExisting(Booking booking, Driver driver, Vehicle vehicle, boolean release) {
        jdbc.update("""
                UPDATE bookings SET status='COMPLETED', assigned_driver_id=?, assigned_vehicle_id=?,
                    driver_accepted_at=CURRENT_TIMESTAMP, driver_arrived_at=CURRENT_TIMESTAMP,
                    passenger_onboard_at=CURRENT_TIMESTAMP, trip_started_at=CURRENT_TIMESTAMP,
                    trip_completed_at=CURRENT_TIMESTAMP,
                    driver_released_at=CASE WHEN ? THEN CURRENT_TIMESTAMP ELSE NULL END,
                    version=version+1 WHERE id=?
                """, driver.getId(), vehicle.getId(), release, booking.getId());
    }

    private String bearer(User user) { return "Bearer " + jwt.createAccessToken(user); }
}
