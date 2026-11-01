package com.gomove.admin;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.auth.domain.*;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.auth.infrastructure.AuthProperties;
import com.gomove.booking.domain.*;
import com.gomove.booking.service.BookingApplicationService;
import com.gomove.booking.service.BookingCancellationService;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.common.exception.DomainException;
import com.gomove.dispatch.service.DriverOfferService;
import com.gomove.dispatch.infrastructure.DispatchStore;
import com.gomove.driver.domain.*;
import com.gomove.driver.service.DriverService;
import com.gomove.pricing.domain.*;
import com.gomove.pricing.engine.PricingEngine;
import com.gomove.vehicle.domain.*;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.UUID;
import java.util.Date;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@AutoConfigureMockMvc
class AdminManagementIntegrationTest extends BaseIntegrationTest {
    @Autowired MockMvc mvc;
    @Autowired JwtTokenProvider jwt;
    @Autowired AuthProperties authProperties;
    @Autowired ObjectMapper mapper;
    @Autowired JdbcTemplate jdbc;
    @Autowired UserRepository users;
    @Autowired DriverRepository drivers;
    @Autowired VehicleRepository vehicles;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired BookingApplicationService bookingService;
    @Autowired BookingCancellationService cancellations;
    @Autowired DispatchStore dispatch;
    @Autowired DriverOfferService offers;
    @Autowired DriverService driverService;
    @Autowired PricingEngine pricing;

    @Test void adminOnlyReadEndpointsAndBoundedPagination() throws Exception {
        User admin = user(UserRole.ADMIN);
        User customer = user(UserRole.CUSTOMER);
        Driver driver = driver(DriverApprovalStatus.PENDING, DriverOperatingStatus.OFFLINE);
        for (String path : new String[]{"/api/v1/admin/dashboard", "/api/v1/admin/drivers",
                "/api/v1/admin/accounts", "/api/v1/admin/bookings",
                "/api/v1/admin/drivers/" + driver.getPublicId(),
                "/api/v1/admin/accounts/" + customer.getPublicId()}) {
            mvc.perform(get(path)).andExpect(status().isUnauthorized());
            mvc.perform(get(path).header("Authorization", bearer(customer))).andExpect(status().isForbidden());
            mvc.perform(get(path).header("Authorization", bearer(driver.getUser()))).andExpect(status().isForbidden());
            mvc.perform(get(path).header("Authorization", bearer(admin))).andExpect(status().isOk());
        }
        mvc.perform(get("/api/v1/admin/drivers?size=51").header("Authorization", bearer(admin)))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.code").value("INVALID_ADMIN_QUERY"));
        mvc.perform(get("/api/v1/admin/accounts?page=-1").header("Authorization", bearer(admin)))
                .andExpect(status().isBadRequest());
        mvc.perform(get("/api/v1/admin/bookings?status=NOT_A_STATUS").header("Authorization", bearer(admin)))
                .andExpect(status().isBadRequest());
        String expired = Jwts.builder().subject(admin.getPublicId().toString())
                .claim("publicId", admin.getPublicId().toString()).claim("role", "ADMIN")
                .issuedAt(Date.from(Instant.now().minusSeconds(3600)))
                .expiration(Date.from(Instant.now().minusSeconds(1800)))
                .signWith(Keys.hmacShaKeyFor(authProperties.getJwtSecret().getBytes(StandardCharsets.UTF_8)))
                .compact();
        mvc.perform(get("/api/v1/admin/dashboard").header("Authorization", "Bearer " + expired))
                .andExpect(status().isUnauthorized());
    }

    @Test void driverAccountSearchDetailAndExistingApprovalAudit() throws Exception {
        User admin = user(UserRole.ADMIN);
        Driver driver = driver(DriverApprovalStatus.PENDING, DriverOperatingStatus.OFFLINE);
        Vehicle vehicle = vehicle(driver);
        String q = driver.getLicenseNumber();
        mvc.perform(get("/api/v1/admin/drivers").param("approvalStatus", "PENDING").param("q", q)
                        .header("Authorization", bearer(admin)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.total").value(1))
                .andExpect(jsonPath("$.data.items[0].publicId").value(driver.getPublicId().toString()));
        mvc.perform(get("/api/v1/admin/drivers/" + driver.getPublicId())
                        .header("Authorization", bearer(admin)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.vehicles[0].publicId").value(vehicle.getPublicId().toString()))
                .andExpect(jsonPath("$.data.operatingStatus").value("OFFLINE"));
        mvc.perform(get("/api/v1/admin/accounts").param("role", "DRIVER")
                        .param("q", driver.getUser().getPhone()).header("Authorization", bearer(admin)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.total").value(1))
                .andExpect(jsonPath("$.data.items[0].driverApprovalStatus").value("PENDING"));
        mvc.perform(get("/api/v1/admin/accounts/" + driver.getUser().getPublicId())
                        .header("Authorization", bearer(admin)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.role").value("DRIVER"))
                .andExpect(jsonPath("$.data.passwordHash").doesNotExist());
        String path = "/api/v1/drivers/" + driver.getPublicId() + "/approval-status";
        for (String status : new String[]{"APPROVED", "APPROVED", "SUSPENDED", "REJECTED"}) {
            mvc.perform(patch(path).header("Authorization", bearer(admin))
                    .contentType(MediaType.APPLICATION_JSON).content("{\"status\":\"" + status + "\"}"))
                    .andExpect(status().isOk()).andExpect(jsonPath("$.data.approvalStatus").value(status));
        }
        assertThat(jdbc.queryForObject("""
                SELECT string_agg(outcome, ',' ORDER BY id) FROM admin_action_audit
                WHERE target_public_id = ?
                """, String.class, driver.getPublicId()))
                .isEqualTo("APPLIED,UNCHANGED,APPLIED,APPLIED");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM admin_action_audit WHERE admin_user_public_id=?",
                Long.class, admin.getPublicId())).isEqualTo(4);
    }

    @Test void activeBookingBlocksSuspensionAndRejectWithoutAudit() {
        User admin = user(UserRole.ADMIN);
        Driver driver = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE);
        Vehicle vehicle = vehicle(driver);
        Booking booking = booking(user(UserRole.CUSTOMER));
        assign(booking, driver, vehicle);
        for (DriverApprovalStatus target : new DriverApprovalStatus[]{DriverApprovalStatus.SUSPENDED,
                DriverApprovalStatus.REJECTED}) {
            assertThatThrownBy(() -> driverService.updateApprovalStatusAsAdmin(admin.getPublicId(),
                    UserRole.ADMIN, driver.getPublicId(), target))
                    .isInstanceOf(DomainException.class)
                    .extracting(ex -> ((DomainException) ex).getCode())
                    .isEqualTo("DRIVER_HAS_UNRELEASED_BOOKING");
        }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM admin_action_audit WHERE target_public_id=?",
                Long.class, driver.getPublicId())).isZero();
        assertThat(jdbc.queryForObject("SELECT approval_status FROM drivers WHERE id=?",
                String.class, driver.getId())).isEqualTo("APPROVED");
    }

    @Test void dashboardSeparatesCollectibleCashFromVoidedTerminalPlaceholders() throws Exception {
        User admin = user(UserRole.ADMIN);
        Booking cancelled = booking(user(UserRole.CUSTOMER));
        Booking failed = booking(user(UserRole.CUSTOMER));
        Booking completed = booking(user(UserRole.CUSTOMER));
        Driver driver = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.BUSY);
        Vehicle vehicle = vehicle(driver);
        UUID cancelledCustomer = jdbc.queryForObject("SELECT u.public_id FROM users u JOIN bookings b ON b.customer_id=u.id WHERE b.id=?",
                UUID.class, cancelled.getId());
        cancellations.cancel(cancelled.getPublicId(), cancelledCustomer, UserRole.CUSTOMER);
        dispatch.failNoDriver(failed.getId(), Instant.now());
        complete(completed, driver, vehicle);
        assertThat(paymentStatus(cancelled)).isEqualTo("VOID");
        assertThat(paymentStatus(failed)).isEqualTo("VOID");
        assertThat(paymentStatus(completed)).isEqualTo("PENDING");
        String body = mvc.perform(get("/api/v1/admin/dashboard").header("Authorization", bearer(admin)))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
        var data = mapper.readTree(body).path("data");
        assertThat(data.path("voidCashPayments").asLong()).isGreaterThanOrEqualTo(2);
        assertThat(data.path("collectiblePendingCashPayments").asLong()).isGreaterThanOrEqualTo(1);
        assertThat(new BigDecimal(data.path("collectiblePendingCashAmount").asText()))
                .isGreaterThanOrEqualTo(completed.getFinalFare());
        assertThat(jdbc.queryForObject("SELECT count(*) FROM driver_commission_ledger WHERE booking_id IN (?,?,?)",
                Long.class, cancelled.getId(), failed.getId(), completed.getId())).isZero();
        mvc.perform(get("/api/v1/admin/bookings").param("status", "CANCELLED")
                .header("Authorization", bearer(admin))).andExpect(status().isOk());
        assertThat(jdbc.queryForObject("SELECT count(*) FROM bookings WHERE quote_id=?",
                Long.class, completed.getQuote().getId())).isEqualTo(1);
    }

    @Test void concurrentAdminSuspensionAndOfferAcceptanceNeverLeaveSuspendedAssignedDriver() throws Exception {
        User admin = user(UserRole.ADMIN);
        Driver driver = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE);
        Vehicle vehicle = vehicle(driver);
        Booking booking = booking(user(UserRole.CUSTOMER));
        jdbc.update("UPDATE bookings SET status='SEARCHING_DRIVER', version=version+1 WHERE id=?", booking.getId());
        UUID offerId = UUID.randomUUID();
        Instant at = Instant.now();
        jdbc.update("""
                INSERT INTO booking_driver_offers
                    (public_id, booking_id, driver_id, vehicle_id, status, offered_at, expires_at)
                VALUES (?, ?, ?, ?, 'PENDING', ?, ?)
                """, offerId, booking.getId(), driver.getId(), vehicle.getId(),
                Timestamp.from(at), Timestamp.from(at.plusSeconds(15)));
        var pool = Executors.newFixedThreadPool(2);
        var ready = new CountDownLatch(2);
        var start = new CountDownLatch(1);
        try {
            var suspend = pool.submit(() -> {
                ready.countDown(); start.await();
                try { driverService.updateApprovalStatusAsAdmin(admin.getPublicId(), UserRole.ADMIN,
                        driver.getPublicId(), DriverApprovalStatus.SUSPENDED); return "SUSPENDED"; }
                catch (DomainException ex) { return ex.getCode(); }
            });
            var accept = pool.submit(() -> {
                ready.countDown(); start.await();
                try { offers.accept(driver.getUser().getPublicId(), UserRole.DRIVER, offerId); return "ACCEPTED"; }
                catch (DomainException ex) { return ex.getCode(); }
            });
            assertThat(ready.await(5, TimeUnit.SECONDS)).isTrue();
            start.countDown();
            String suspended = suspend.get(10, TimeUnit.SECONDS);
            String accepted = accept.get(10, TimeUnit.SECONDS);
            assertThat(suspended).isIn("SUSPENDED", "DRIVER_HAS_UNRELEASED_BOOKING");
            assertThat(accepted).isIn("ACCEPTED", "DRIVER_UNAVAILABLE");
            assertThat("SUSPENDED".equals(suspended) && "ACCEPTED".equals(accepted)).isFalse();
        } finally { pool.shutdownNow(); }
        String approval = jdbc.queryForObject("SELECT approval_status FROM drivers WHERE id=?",
                String.class, driver.getId());
        String bookingStatus = jdbc.queryForObject("SELECT status FROM bookings WHERE id=?",
                String.class, booking.getId());
        assertThat("SUSPENDED".equals(approval) && "DRIVER_ACCEPTED".equals(bookingStatus)).isFalse();
    }

    private User user(UserRole role) {
        String code = UUID.randomUUID().toString().substring(0, 8);
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                code + "@example.test", "hash", "Admin Test " + code);
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private Driver driver(DriverApprovalStatus approval, DriverOperatingStatus operating) {
        Driver driver = new Driver(user(UserRole.DRIVER), "ADMIN-" + UUID.randomUUID());
        driver.setApprovalStatus(approval);
        driver.setOperatingStatus(operating);
        return drivers.saveAndFlush(driver);
    }

    private Vehicle vehicle(Driver driver) {
        Vehicle vehicle = new Vehicle(driver, "ADM-" + UUID.randomUUID().toString().substring(0, 12),
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
        String body = bookingService.create(customer.getPublicId(), UserRole.CUSTOMER,
                quote.getPublicId(), UUID.randomUUID().toString()).responseBody();
        try {
            UUID id = UUID.fromString(mapper.readTree(body).path("data").path("bookingPublicId").asText());
            return bookings.findOwned(id, customer.getPublicId()).orElseThrow();
        } catch (Exception ex) { throw new IllegalStateException(ex); }
    }

    private void assign(Booking booking, Driver driver, Vehicle vehicle) {
        jdbc.update("""
                UPDATE bookings SET status='DRIVER_ACCEPTED', assigned_driver_id=?, assigned_vehicle_id=?,
                    driver_accepted_at=CURRENT_TIMESTAMP, version=version+1 WHERE id=?
                """, driver.getId(), vehicle.getId(), booking.getId());
        jdbc.update("UPDATE drivers SET operating_status='BUSY', version=version+1 WHERE id=?", driver.getId());
    }

    private void complete(Booking booking, Driver driver, Vehicle vehicle) {
        jdbc.update("""
                UPDATE bookings SET status='COMPLETED', assigned_driver_id=?, assigned_vehicle_id=?,
                    driver_accepted_at=CURRENT_TIMESTAMP, driver_arrived_at=CURRENT_TIMESTAMP,
                    passenger_onboard_at=CURRENT_TIMESTAMP, trip_started_at=CURRENT_TIMESTAMP,
                    trip_completed_at=CURRENT_TIMESTAMP, version=version+1 WHERE id=?
                """, driver.getId(), vehicle.getId(), booking.getId());
    }

    private String paymentStatus(Booking booking) {
        return jdbc.queryForObject("SELECT status FROM cash_payments WHERE booking_id=?",
                String.class, booking.getId());
    }

    private String bearer(User user) { return "Bearer " + jwt.createAccessToken(user); }
}
