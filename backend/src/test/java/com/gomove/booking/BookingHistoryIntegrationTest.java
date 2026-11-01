package com.gomove.booking;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.auth.domain.UserRole;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.booking.domain.Booking;
import com.gomove.booking.domain.BookingRepository;
import com.gomove.booking.service.BookingApplicationService;
import com.gomove.cash.service.CashSettlementApplicationService;
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
import com.gomove.vehicle.domain.Vehicle;
import com.gomove.vehicle.domain.VehicleRepository;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@AutoConfigureMockMvc
class BookingHistoryIntegrationTest extends BaseIntegrationTest {
    private static final String HISTORY = "/api/v1/bookings/history";

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired UserRepository users;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired BookingApplicationService bookingService;
    @Autowired CashSettlementApplicationService cash;
    @Autowired DriverRepository drivers;
    @Autowired VehicleRepository vehicles;
    @Autowired PricingEngine pricing;
    @Autowired JdbcTemplate jdbc;
    @Autowired JwtTokenProvider jwt;

    @Test
    void completedOnlyPagedAndStableWithPendingAndPaidCash() throws Exception {
        User owner = user(UserRole.CUSTOMER);
        User other = user(UserRole.CUSTOMER);
        Instant completedAt = Instant.now().minusSeconds(10);
        Booking first = completed(owner, completedAt, false);
        Booking second = completed(owner, completedAt, true);
        Booking third = completed(owner, completedAt, false);
        Booking unrelated = completed(other, completedAt, false);
        Booking active = booking(owner);

        JsonNode firstPage = data(owner, 0, 2);
        assertThat(firstPage.path("totalElements").asLong()).isEqualTo(3);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM pg_indexes WHERE indexname='idx_bookings_customer_completed_history'",
                Integer.class)).isEqualTo(1);
        assertThat(firstPage.path("hasNext").asBoolean()).isTrue();
        assertThat(firstPage.path("items").size()).isEqualTo(2);
        assertThat(firstPage.path("items").get(0).path("bookingPublicId").asText())
                .isEqualTo(third.getPublicId().toString());
        assertThat(firstPage.path("items").get(1).path("bookingPublicId").asText())
                .isEqualTo(second.getPublicId().toString());
        assertThat(firstPage.path("items").get(0).path("paymentStatus").asText()).isEqualTo("PENDING");
        assertThat(firstPage.path("items").get(1).path("paymentStatus").asText()).isEqualTo("PAID");
        JsonNode item = firstPage.path("items").get(0);
        assertThat(item.path("pickupLatitude").asDouble()).isEqualTo(21.0287);
        assertThat(item.path("pickupLongitude").asDouble()).isEqualTo(105.8524);
        assertThat(item.path("dropoffLatitude").asDouble()).isEqualTo(21.0245);
        assertThat(item.path("dropoffLongitude").asDouble()).isEqualTo(105.8576);
        assertThat(item.path("finalFare").decimalValue()).isEqualByComparingTo(third.getFinalFare());
        for (String hidden : new String[] {"id", "customerId", "paymentPublicId", "paidAt",
                "driverPublicId", "vehiclePublicId", "phoneNumber", "pricingSnapshot"}) {
            assertThat(item.has(hidden)).isFalse();
        }

        JsonNode lastPage = data(owner, 1, 2);
        assertThat(lastPage.path("hasNext").asBoolean()).isFalse();
        assertThat(lastPage.path("items").size()).isEqualTo(1);
        assertThat(lastPage.path("items").get(0).path("bookingPublicId").asText())
                .isEqualTo(first.getPublicId().toString());
        assertThat(data(owner, 2, 2).path("items").isEmpty()).isTrue();
        assertThat(data(other, 0, 20).path("items").get(0).path("bookingPublicId").asText())
                .isEqualTo(unrelated.getPublicId().toString());
        assertThat(data(user(UserRole.CUSTOMER), 0, 20).path("totalElements").asLong()).isZero();
        assertThat(bookings.countByQuoteId(active.getQuote().getId())).isEqualTo(1);
        assertThat(bookings.countByQuoteId(first.getQuote().getId())).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT final_fare FROM bookings WHERE id=?", BigDecimal.class,
                first.getId())).isEqualByComparingTo(first.getFinalFare());
    }

    @Test
    void rolesOwnershipDetailPaymentAndPaginationValidation() throws Exception {
        User owner = user(UserRole.CUSTOMER);
        User stranger = user(UserRole.CUSTOMER);
        User driver = user(UserRole.DRIVER);
        Booking booking = completed(owner, Instant.now().minusSeconds(10), false);

        mvc.perform(get(HISTORY)).andExpect(status().isUnauthorized());
        mvc.perform(get(HISTORY).header("Authorization", bearer(driver)))
                .andExpect(status().isForbidden());
        mvc.perform(get(HISTORY).header("Authorization", bearer(owner)).param("page", "-1"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("INVALID_PAGINATION"));
        mvc.perform(get(HISTORY).header("Authorization", bearer(owner)).param("size", "51"))
                .andExpect(status().isBadRequest());
        mvc.perform(get(HISTORY).header("Authorization", bearer(owner)).param("page", "10001"))
                .andExpect(status().isBadRequest());
        mvc.perform(get(HISTORY).header("Authorization", bearer(owner))
                        .param("customerPublicId", stranger.getPublicId().toString()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.totalElements").value(1));
        mvc.perform(get(HISTORY).header("Authorization", bearer(stranger)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.totalElements").value(0));

        String detail = "/api/v1/bookings/" + booking.getPublicId();
        mvc.perform(get(detail).header("Authorization", bearer(stranger)))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.code").value("BOOKING_NOT_FOUND"));
        mvc.perform(get(detail).header("Authorization", bearer(owner)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.status").value("COMPLETED"))
                .andExpect(jsonPath("$.data.pickupLatitude").value(21.0287))
                .andExpect(jsonPath("$.data.dropoffLongitude").value(105.8576))
                .andExpect(jsonPath("$.data.distanceMeters").isNumber())
                .andExpect(jsonPath("$.data.durationSeconds").isNumber())
                .andExpect(jsonPath("$.data.tripCompletedAt").exists());
        mvc.perform(get(detail + "/payment").header("Authorization", bearer(stranger)))
                .andExpect(status().isNotFound());
        mvc.perform(get(detail + "/payment").header("Authorization", bearer(owner)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.status").value("PENDING"))
                .andExpect(jsonPath("$.data.paidAt").doesNotExist());
    }

    private JsonNode data(User owner, int page, int size) throws Exception {
        return mapper.readTree(mvc.perform(get(HISTORY).header("Authorization", bearer(owner))
                        .param("page", Integer.toString(page)).param("size", Integer.toString(size)))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString()).path("data");
    }

    private Booking completed(User customer, Instant at, boolean paid) {
        Booking booking = booking(customer);
        Driver driver = driver();
        Vehicle vehicle = new Vehicle(driver, "HIST-" + UUID.randomUUID().toString().substring(0, 12),
                VehicleType.MOTORBIKE, "Test", "Test", "White");
        vehicle.setActive(true);
        vehicle = vehicles.saveAndFlush(vehicle);
        jdbc.update("UPDATE drivers SET operating_status='BUSY', version=version+1 WHERE id=?",
                driver.getId());
        jdbc.update("""
                UPDATE bookings SET status='COMPLETED', assigned_driver_id=?, assigned_vehicle_id=?,
                    driver_accepted_at=?, driver_arrived_at=?, passenger_onboard_at=?,
                    trip_started_at=?, trip_completed_at=?, version=version+1 WHERE id=?
                """, driver.getId(), vehicle.getId(), Timestamp.from(at.minusSeconds(4)),
                Timestamp.from(at.minusSeconds(3)), Timestamp.from(at.minusSeconds(2)),
                Timestamp.from(at.minusSeconds(1)), Timestamp.from(at), booking.getId());
        if (paid) cash.confirm(booking.getPublicId(), driver.getUser().getPublicId(), UserRole.DRIVER);
        return booking;
    }

    private Booking booking(User customer) {
        RouteEstimate route = new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "TEST_ROUTER");
        Quote quote = quotes.saveAndFlush(new Quote(customer,
                new GeoCoordinate(new BigDecimal("21.0287"), new BigDecimal("105.8524")),
                new GeoCoordinate(new BigDecimal("21.0245"), new BigDecimal("105.8576")),
                VehicleType.MOTORBIKE, route, pricing.calculate(VehicleType.MOTORBIKE, route), Instant.now()));
        String response = bookingService.create(customer.getPublicId(), UserRole.CUSTOMER,
                quote.getPublicId(), UUID.randomUUID().toString()).responseBody();
        try {
            UUID publicId = UUID.fromString(mapper.readTree(response).path("data").path("bookingPublicId").asText());
            return bookings.findOwned(publicId, customer.getPublicId()).orElseThrow();
        } catch (Exception ex) {
            throw new IllegalStateException(ex);
        }
    }

    private User user(UserRole role) {
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "history-" + UUID.randomUUID() + "@example.test", "hash", "History Test");
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private Driver driver() {
        Driver driver = new Driver(user(UserRole.DRIVER), "HIST-" + UUID.randomUUID());
        driver.setApprovalStatus(DriverApprovalStatus.APPROVED);
        driver.setOperatingStatus(DriverOperatingStatus.ONLINE);
        return drivers.saveAndFlush(driver);
    }

    private String bearer(User user) {
        return "Bearer " + jwt.createAccessToken(user);
    }
}
