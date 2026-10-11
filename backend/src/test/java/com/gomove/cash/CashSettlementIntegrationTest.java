package com.gomove.cash;

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
import com.gomove.cash.api.CashReceiptResponse;
import com.gomove.cash.infrastructure.CashSettlementStore;
import com.gomove.cash.service.CashSettlementApplicationService;
import com.gomove.cash.service.CashSettlementTransactionService;
import com.gomove.cash.service.CommissionCalculator;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.common.exception.DomainException;
import com.gomove.driver.domain.Driver;
import com.gomove.driver.domain.DriverApprovalStatus;
import com.gomove.driver.domain.DriverOperatingStatus;
import com.gomove.driver.domain.DriverRepository;
import com.gomove.driver.service.DriverService;
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
import org.springframework.dao.DataAccessException;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Clock;
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
class CashSettlementIntegrationTest extends BaseIntegrationTest {
    @Autowired UserRepository users;
    @Autowired DriverRepository drivers;
    @Autowired VehicleRepository vehicles;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired BookingApplicationService bookingService;
    @Autowired CashSettlementApplicationService cash;
    @Autowired CashSettlementStore cashStore;
    @Autowired PlatformTransactionManager transactionManager;
    @Autowired TripApplicationService trips;
    @Autowired DriverService driverService;
    @Autowired PricingEngine pricing;
    @Autowired JdbcTemplate jdbc;
    @Autowired MockMvc mvc;
    @Autowired JwtTokenProvider jwt;
    @Autowired ObjectMapper mapper;

    @Test
    void newBookingHasOnePendingCashPaymentAndIdempotentRetryPreservesResponse() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        Quote quote = quote(customer, VehicleType.MOTORBIKE);
        String key = UUID.randomUUID().toString();
        String first = bookingService.create(customer.getPublicId(), UserRole.CUSTOMER,
                quote.getPublicId(), key).responseBody();
        String replay = bookingService.create(customer.getPublicId(), UserRole.CUSTOMER,
                quote.getPublicId(), key).responseBody();
        assertThat(replay).isEqualTo(first);
        UUID bookingPublicId = UUID.fromString(mapper.readTree(first).path("data").path("bookingPublicId").asText());
        Booking booking = bookings.findOwned(bookingPublicId, customer.getPublicId()).orElseThrow();
        assertThat(paymentCount(booking)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT status FROM cash_payments WHERE booking_id=?",
                String.class, booking.getId())).isEqualTo("PENDING");
        assertThat(jdbc.queryForObject("SELECT amount FROM cash_payments WHERE booking_id=?",
                BigDecimal.class, booking.getId())).isEqualByComparingTo(booking.getFinalFare());
    }

    @Test
    void completedTripSettlesExactlyOnceAndReplayReturnsDurableReceipt() throws Exception {
        Ride ride = completedRide(VehicleType.MOTORBIKE);
        String url = confirmUrl(ride.booking());
        mvc.perform(get(paymentUrl(ride.booking())).header("Authorization", bearer(ride.customer())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.status").value("PENDING"));
        String response = mvc.perform(post(url).header("Authorization", bearer(ride.driver().getUser()))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"amount\":1,\"commissionRate\":0,\"driverId\":999}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.paymentStatus").value("PAID"))
                .andExpect(jsonPath("$.data.commissionPolicyVersion").value("CASH_MVP_V1"))
                .andReturn().getResponse().getContentAsString();
        JsonNode publicData = mapper.readTree(response).path("data");
        assertThat(publicData.has("id")).isFalse();
        assertThat(publicData.has("driverId")).isFalse();
        assertThat(response).doesNotContain("passwordHash", "jwtSecret", "accessToken");
        CashReceiptResponse original = cash.confirm(ride.booking().getPublicId(),
                ride.driver().getUser().getPublicId(), UserRole.DRIVER);
        CashReceiptResponse replay = cash.confirm(ride.booking().getPublicId(),
                ride.driver().getUser().getPublicId(), UserRole.DRIVER);
        assertThat(replay).isEqualTo(original);
        assertThat(original.cashCollectedAmount()).isEqualByComparingTo(ride.booking().getFinalFare());
        assertThat(original.commissionAmount()).isEqualByComparingTo(
                ride.booking().getFinalFare().multiply(new BigDecimal("0.20")));
        assertThat(original.paidAt()).isAfterOrEqualTo(bookings.findById(ride.booking().getId())
                .orElseThrow().getTripCompletedAt());
        assertThat(original.driverReleasedAt()).isAfterOrEqualTo(original.paidAt());
        assertThat(bookings.findById(ride.booking().getId()).orElseThrow().getStatus())
                .isEqualTo(BookingStatus.COMPLETED);
        assertThat(bookings.findById(ride.booking().getId()).orElseThrow().getAssignedDriver().getId())
                .isEqualTo(ride.driver().getId());
        assertThat(drivers.findById(ride.driver().getId()).orElseThrow().getOperatingStatus())
                .isEqualTo(DriverOperatingStatus.ONLINE);
        assertThat(ledgerCount(ride.booking())).isEqualTo(1);
        mvc.perform(get(paymentUrl(ride.booking())).header("Authorization", bearer(ride.customer())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.status").value("PAID"));
        mvc.perform(get("/api/v1/drivers/me/commissions/summary")
                        .header("Authorization", bearer(ride.driver().getUser())))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.outstandingCommissionDue")
                        .value(original.commissionAmount().doubleValue()));
    }

    @Test
    void replayWhileBusyOnAnotherBookingDoesNotChangeCurrentAssignment() {
        Ride first = completedRide(VehicleType.CAR_4_SEAT);
        CashReceiptResponse receipt = cash.confirm(first.booking().getPublicId(),
                first.driver().getUser().getPublicId(), UserRole.DRIVER);
        Ride second = assign(newRide(VehicleType.CAR_4_SEAT), first.driver());
        assertThat(cash.confirm(first.booking().getPublicId(), first.driver().getUser().getPublicId(),
                UserRole.DRIVER)).isEqualTo(receipt);
        assertThat(drivers.findById(first.driver().getId()).orElseThrow().getOperatingStatus())
                .isEqualTo(DriverOperatingStatus.BUSY);
        assertThat(bookings.findById(second.booking().getId()).orElseThrow().getDriverReleasedAt()).isNull();
        assertThat(ledgerCount(first.booking())).isEqualTo(1);
    }

    @Test
    void authorizationMasksUnrelatedBookingsAndRejectsCustomerConfirmation() throws Exception {
        Ride ride = completedRide(VehicleType.CAR_7_SEAT);
        User strangerCustomer = user(UserRole.CUSTOMER);
        Driver strangerDriver = driver();
        mvc.perform(post(confirmUrl(ride.booking()))).andExpect(status().isUnauthorized());
        mvc.perform(get(paymentUrl(ride.booking()))).andExpect(status().isUnauthorized());
        mvc.perform(get("/api/v1/drivers/me/commissions/summary")).andExpect(status().isUnauthorized());
        mvc.perform(post(confirmUrl(ride.booking())).header("Authorization", bearer(ride.customer())))
                .andExpect(status().isForbidden());
        mvc.perform(post(confirmUrl(ride.booking())).header("Authorization", bearer(strangerDriver.getUser())))
                .andExpect(status().isNotFound());
        mvc.perform(get(paymentUrl(ride.booking())).header("Authorization", bearer(strangerCustomer)))
                .andExpect(status().isNotFound());
        mvc.perform(get(paymentUrl(ride.booking())).header("Authorization", bearer(strangerDriver.getUser())))
                .andExpect(status().isNotFound());
        mvc.perform(get(paymentUrl(ride.booking())).header("Authorization", bearer(ride.driver().getUser())))
                .andExpect(status().isOk());
        mvc.perform(get("/api/v1/drivers/me/commissions/summary")
                        .header("Authorization", bearer(strangerDriver.getUser())))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.outstandingCommissionDue").value(0));
        assertThat(ledgerCount(ride.booking())).isZero();
    }

    @Test
    void confirmationBeforeCompletedFailsWithoutFinancialEffects() {
        Ride ride = assign(newRide(VehicleType.MOTORBIKE), driver());
        assertThatThrownBy(() -> cash.confirm(ride.booking().getPublicId(),
                ride.driver().getUser().getPublicId(), UserRole.DRIVER))
                .isInstanceOf(DomainException.class)
                .extracting(ex -> ((DomainException) ex).getCode()).isEqualTo("CASH_SETTLEMENT_CONFLICT");
        assertPendingBusyUnreleased(ride);
    }

    @Test
    void simultaneousConfirmationsSerializeAndReturnOneReceipt() throws Exception {
        Ride ride = completedRide(VehicleType.MOTORBIKE);
        var pool = Executors.newFixedThreadPool(2);
        var ready = new CountDownLatch(2);
        var start = new CountDownLatch(1);
        Callable<CashReceiptResponse> task = () -> {
            ready.countDown();
            start.await();
            return cash.confirm(ride.booking().getPublicId(), ride.driver().getUser().getPublicId(),
                    UserRole.DRIVER);
        };
        try {
            var first = pool.submit(task);
            var second = pool.submit(task);
            assertThat(ready.await(5, TimeUnit.SECONDS)).isTrue();
            start.countDown();
            assertThat(first.get(20, TimeUnit.SECONDS)).isEqualTo(second.get(20, TimeUnit.SECONDS));
        } finally { pool.shutdownNow(); }
        assertThat(ledgerCount(ride.booking())).isEqualTo(1);
        assertThat(drivers.findById(ride.driver().getId()).orElseThrow().getOperatingStatus())
                .isEqualTo(DriverOperatingStatus.ONLINE);
    }

    @Test
    void concurrentDriverStatusOperationCannotCreatePartialSettlement() throws Exception {
        Ride ride = completedRide(VehicleType.MOTORBIKE);
        var pool = Executors.newFixedThreadPool(2);
        var ready = new CountDownLatch(2);
        var start = new CountDownLatch(1);
        Callable<CashReceiptResponse> settle = () -> {
            ready.countDown();
            start.await();
            return cash.confirm(ride.booking().getPublicId(), ride.driver().getUser().getPublicId(),
                    UserRole.DRIVER);
        };
        Callable<String> operate = () -> {
            ready.countDown();
            start.await();
            try {
                driverService.setOwnOperatingStatus(ride.driver().getUser().getPublicId(),
                        UserRole.DRIVER, DriverOperatingStatus.OFFLINE);
                return "OFFLINE";
            } catch (DomainException ex) {
                return ex.getCode();
            } catch (org.springframework.orm.ObjectOptimisticLockingFailureException ex) {
                return "OPTIMISTIC_CONFLICT";
            }
        };
        String operatingOutcome;
        try {
            var settled = pool.submit(settle);
            var operating = pool.submit(operate);
            assertThat(ready.await(5, TimeUnit.SECONDS)).isTrue();
            start.countDown();
            assertThat(settled.get(20, TimeUnit.SECONDS).paymentStatus()).isEqualTo("PAID");
            operatingOutcome = operating.get(20, TimeUnit.SECONDS);
        } finally { pool.shutdownNow(); }
        assertThat(operatingOutcome).isIn("OFFLINE", "DRIVER_HAS_UNRELEASED_BOOKING", "OPTIMISTIC_CONFLICT");
        assertThat(bookings.findById(ride.booking().getId()).orElseThrow().getDriverReleasedAt()).isNotNull();
        assertThat(ledgerCount(ride.booking())).isEqualTo(1);
        assertThat(drivers.findById(ride.driver().getId()).orElseThrow().getOperatingStatus())
                .isEqualTo("OFFLINE".equals(operatingOutcome)
                        ? DriverOperatingStatus.OFFLINE : DriverOperatingStatus.ONLINE);
    }

    @Test
    void databaseFailureAfterLedgerInsertRollsBackEverything() {
        Ride ride = completedRide(VehicleType.MOTORBIKE);
        jdbc.execute("ALTER TABLE cash_payments ADD CONSTRAINT test_v13_block_paid CHECK (status <> 'PAID') NOT VALID");
        try {
            assertThatThrownBy(() -> cash.confirm(ride.booking().getPublicId(),
                    ride.driver().getUser().getPublicId(), UserRole.DRIVER)).isInstanceOf(RuntimeException.class);
        } finally {
            jdbc.execute("ALTER TABLE cash_payments DROP CONSTRAINT test_v13_block_paid");
        }
        assertPendingBusyUnreleased(ride);
        assertThat(ledgerCount(ride.booking())).isZero();
    }

    @Test
    void databaseFailureAfterPaymentUpdateRollsBackEverything() {
        Ride ride = completedRide(VehicleType.MOTORBIKE);
        jdbc.execute("ALTER TABLE bookings ADD CONSTRAINT test_v13_block_release CHECK (driver_released_at IS NULL) NOT VALID");
        try {
            assertThatThrownBy(() -> cash.confirm(ride.booking().getPublicId(),
                    ride.driver().getUser().getPublicId(), UserRole.DRIVER)).isInstanceOf(RuntimeException.class);
        } finally {
            jdbc.execute("ALTER TABLE bookings DROP CONSTRAINT test_v13_block_release");
        }
        assertPendingBusyUnreleased(ride);
        assertThat(ledgerCount(ride.booking())).isZero();
    }

    @Test
    void databaseConstraintsProtectPaymentAndAppendOnlyLedger() {
        Ride ride = completedRide(VehicleType.MOTORBIKE);
        assertThatThrownBy(() -> jdbc.update("""
                INSERT INTO cash_payments (public_id, booking_id, amount, currency_code)
                VALUES (?, ?, ?, 'VND')
                """, UUID.randomUUID(), ride.booking().getId(), ride.booking().getFinalFare()))
                .isInstanceOf(DataIntegrityViolationException.class);
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE cash_payments SET status='PAID' WHERE booking_id=?
                """, ride.booking().getId())).isInstanceOf(DataIntegrityViolationException.class);
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE cash_payments SET collected_by_driver_id=? WHERE booking_id=?
                """, ride.driver().getId(), ride.booking().getId()))
                .isInstanceOf(DataIntegrityViolationException.class);
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE cash_payments SET amount=amount+1 WHERE booking_id=?
                """, ride.booking().getId())).isInstanceOf(DataAccessException.class);
        assertThatThrownBy(() -> jdbc.update("""
                INSERT INTO driver_commission_ledger
                    (public_id, booking_id, driver_id, event_type, currency_code,
                     gross_cash_fare, commission_rate, commission_amount,
                     commission_policy_version, occurred_at)
                SELECT ?, id, assigned_driver_id, 'COMMISSION_ACCRUED', 'VND',
                       final_fare + 1, 0, 0, 'TEST', CURRENT_TIMESTAMP
                  FROM bookings WHERE id=?
                """, UUID.randomUUID(), ride.booking().getId()))
                .isInstanceOf(DataAccessException.class);
        cash.confirm(ride.booking().getPublicId(), ride.driver().getUser().getPublicId(), UserRole.DRIVER);
        assertThatThrownBy(() -> jdbc.update("DELETE FROM cash_payments WHERE booking_id=?",
                ride.booking().getId())).isInstanceOf(DataAccessException.class);
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE driver_commission_ledger SET commission_amount=0 WHERE booking_id=?
                """, ride.booking().getId())).isInstanceOf(DataAccessException.class);
        assertThatThrownBy(() -> jdbc.update("""
                DELETE FROM driver_commission_ledger WHERE booking_id=?
                """, ride.booking().getId())).isInstanceOf(DataAccessException.class);
        assertThatThrownBy(() -> jdbc.update("""
                INSERT INTO driver_commission_ledger
                    (public_id, booking_id, driver_id, event_type, currency_code,
                     gross_cash_fare, commission_rate, commission_amount,
                     commission_policy_version, occurred_at)
                SELECT ?, booking_id, driver_id, event_type, currency_code,
                       gross_cash_fare, commission_rate, commission_amount,
                       commission_policy_version, occurred_at
                  FROM driver_commission_ledger WHERE booking_id=?
                """, UUID.randomUUID(), ride.booking().getId()))
                .isInstanceOf(DataIntegrityViolationException.class);
        assertThat(ledgerCount(ride.booking())).isEqualTo(1);
    }

    @Test
    void recordedPolicyAndSummaryStayStableAfterAnotherPolicyCalculation() {
        Ride first = completedRide(VehicleType.CAR_4_SEAT);
        Ride second = completedRide(VehicleType.CAR_7_SEAT);
        // Both rides use different Drivers. Add a second completed ride for the first Driver
        // only after release, proving summary is the sum of immutable ledger rows.
        CashReceiptResponse firstReceipt = cash.confirm(first.booking().getPublicId(),
                first.driver().getUser().getPublicId(), UserRole.DRIVER);
        CommissionCalculator changedPolicy = new CommissionCalculator(new BigDecimal("0.50"), "CASH_MVP_V2");
        CashReceiptResponse afterPolicyChange = new TransactionTemplate(transactionManager).execute(status ->
                new CashSettlementTransactionService(cashStore, changedPolicy, Clock.systemUTC())
                        .confirm(first.booking().getPublicId(), first.driver().getUser().getPublicId()));
        assertThat(afterPolicyChange).isEqualTo(firstReceipt);
        cash.confirm(second.booking().getPublicId(), second.driver().getUser().getPublicId(), UserRole.DRIVER);
        Ride third = assign(newRide(VehicleType.CAR_4_SEAT), first.driver());
        complete(third);
        CashReceiptResponse thirdReceipt = cash.confirm(third.booking().getPublicId(),
                first.driver().getUser().getPublicId(), UserRole.DRIVER);
        BigDecimal expected = firstReceipt.commissionAmount().add(thirdReceipt.commissionAmount());
        assertThat(cash.summary(first.driver().getUser().getPublicId(), UserRole.DRIVER)
                .outstandingCommissionDue()).isEqualByComparingTo(expected);
        assertThat(jdbc.queryForObject("""
                SELECT SUM(commission_amount) FROM driver_commission_ledger WHERE driver_id=?
                """, BigDecimal.class, first.driver().getId())).isEqualByComparingTo(expected);
        assertThat(changedPolicy
                .calculate(first.booking().getFinalFare()).commissionDue())
                .isNotEqualByComparingTo(firstReceipt.commissionAmount());
        assertThat(cash.confirm(first.booking().getPublicId(), first.driver().getUser().getPublicId(),
                UserRole.DRIVER)).isEqualTo(firstReceipt);
    }

    private Ride completedRide(VehicleType type) {
        Ride ride = assign(newRide(type), driver());
        complete(ride);
        return ride;
    }

    private void complete(Ride ride) {
        for (TripAction action : TripAction.values()) {
            trips.transition(ride.booking().getPublicId(), ride.driver().getUser().getPublicId(),
                    UserRole.DRIVER, action);
        }
    }

    private Ride newRide(VehicleType type) {
        try {
            User customer = user(UserRole.CUSTOMER);
            Quote quote = quote(customer, type);
            String response = bookingService.create(customer.getPublicId(), UserRole.CUSTOMER,
                    quote.getPublicId(), UUID.randomUUID().toString()).responseBody();
            JsonNode data = mapper.readTree(response).path("data");
            Booking booking = bookings.findOwned(UUID.fromString(data.path("bookingPublicId").asText()),
                    customer.getPublicId()).orElseThrow();
            return new Ride(customer, booking, null);
        } catch (Exception ex) { throw new IllegalStateException(ex); }
    }

    private Ride assign(Ride ride, Driver driver) {
        Vehicle vehicle = vehicles.findByDriverIdAndIsActiveTrue(driver.getId()).orElseGet(() -> {
            Vehicle fresh = new Vehicle(driver, "CASH-" + UUID.randomUUID().toString().substring(0, 12),
                    ride.booking().getVehicleType(), "Test", "Test", "White");
            fresh.setActive(true);
            return vehicles.saveAndFlush(fresh);
        });
        jdbc.update("""
                UPDATE drivers SET operating_status='BUSY', version=version+1 WHERE id=?
                """, driver.getId());
        jdbc.update("""
                UPDATE bookings SET status='DRIVER_ACCEPTED', assigned_driver_id=?,
                    assigned_vehicle_id=?, driver_accepted_at=?, version=version+1 WHERE id=?
                """, driver.getId(), vehicle.getId(), Timestamp.from(Instant.now()), ride.booking().getId());
        return new Ride(ride.customer(), ride.booking(), driver);
    }

    private Quote quote(User customer, VehicleType type) {
        RouteEstimate route = new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "TEST_ROUTER");
        return quotes.saveAndFlush(new Quote(customer,
                new GeoCoordinate(new BigDecimal("21.0287"), new BigDecimal("105.8524")),
                new GeoCoordinate(new BigDecimal("21.0245"), new BigDecimal("105.8576")),
                type, route, pricing.calculate(type, route), Instant.now()));
    }

    private User user(UserRole role) {
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "cash-" + UUID.randomUUID() + "@example.test", "hash", "Cash Test");
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private Driver driver() {
        Driver driver = new Driver(user(UserRole.DRIVER), "CASH-" + UUID.randomUUID());
        driver.setApprovalStatus(DriverApprovalStatus.APPROVED);
        driver.setOperatingStatus(DriverOperatingStatus.ONLINE);
        return drivers.saveAndFlush(driver);
    }

    private void assertPendingBusyUnreleased(Ride ride) {
        assertThat(jdbc.queryForObject("SELECT status FROM cash_payments WHERE booking_id=?",
                String.class, ride.booking().getId())).isEqualTo("PENDING");
        assertThat(bookings.findById(ride.booking().getId()).orElseThrow().getDriverReleasedAt()).isNull();
        assertThat(drivers.findById(ride.driver().getId()).orElseThrow().getOperatingStatus())
                .isEqualTo(DriverOperatingStatus.BUSY);
    }

    private int paymentCount(Booking booking) {
        return jdbc.queryForObject("SELECT COUNT(*) FROM cash_payments WHERE booking_id=?",
                Integer.class, booking.getId());
    }

    private int ledgerCount(Booking booking) {
        return jdbc.queryForObject("SELECT COUNT(*) FROM driver_commission_ledger WHERE booking_id=?",
                Integer.class, booking.getId());
    }

    private String bearer(User user) { return "Bearer " + jwt.createAccessToken(user); }
    private String confirmUrl(Booking booking) {
        return "/api/v1/drivers/me/trips/" + booking.getPublicId() + "/cash/confirm";
    }
    private String paymentUrl(Booking booking) {
        return "/api/v1/bookings/" + booking.getPublicId() + "/payment";
    }
    private record Ride(User customer, Booking booking, Driver driver) {}
}
