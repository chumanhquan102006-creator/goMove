package com.gomove.dispatch;

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
import com.gomove.dispatch.api.DriverOfferResponse;
import com.gomove.dispatch.infrastructure.DispatchStore;
import com.gomove.dispatch.domain.DriverOfferStatus;
import com.gomove.dispatch.service.DispatchCoordinator;
import com.gomove.dispatch.service.DispatchProperties;
import com.gomove.dispatch.service.DispatchTransactionService;
import com.gomove.dispatch.service.DriverOfferService;
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
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.web.servlet.MockMvc;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.Timestamp;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.List;
import java.util.ArrayList;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.locks.LockSupport;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@AutoConfigureMockMvc
@Import(DispatchIntegrationTest.ClockConfiguration.class)
class DispatchIntegrationTest extends BaseIntegrationTest {
    private static final Instant NOW = Instant.parse("2030-01-01T01:00:00Z");
    private static final double LAT = 21.0287;
    private static final double LON = 105.8524;

    @Autowired UserRepository users;
    @Autowired DriverRepository drivers;
    @Autowired VehicleRepository vehicles;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired BookingApplicationService bookingService;
    @Autowired PricingEngine pricing;
    @Autowired DispatchStore store;
    @Autowired DispatchTransactionService transactions;
    @Autowired DispatchCoordinator coordinator;
    @Autowired DispatchProperties properties;
    @Autowired DriverOfferService offers;
    @Autowired JdbcTemplate jdbc;
    @Autowired DataSource dataSource;
    @Autowired MockMvc mvc;
    @Autowired JwtTokenProvider jwt;
    @Autowired ObjectMapper mapper;
    @Autowired MutableClock clock;
    private final List<Long> testDriverIds = new ArrayList<>();

    @BeforeEach
    void resetClock() {
        clock.set(NOW);
    }

    @AfterEach
    void staleOnlyThisTestsDrivers() {
        for (Long driverId : testDriverIds) {
            jdbc.update("UPDATE driver_locations SET updated_at=? WHERE driver_id=?",
                    Timestamp.from(Instant.EPOCH), driverId);
        }
    }

    @Test
    void migrationConstraintsAndNearestVehicleAwareEligibility() {
        Created created = booking(VehicleType.MOTORBIKE);
        Driver eligible = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.0002);
        driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.CAR_4_SEAT, true, NOW, 0.00001);
        driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.OFFLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.00001);
        driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.BUSY,
                VehicleType.MOTORBIKE, true, NOW, 0.00001);
        for (DriverApprovalStatus approval : new DriverApprovalStatus[]{DriverApprovalStatus.PENDING,
                DriverApprovalStatus.REJECTED, DriverApprovalStatus.SUSPENDED}) {
            driver(approval, DriverOperatingStatus.ONLINE, VehicleType.MOTORBIKE, true, NOW, 0.00001);
        }
        driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW.minusSeconds(31), 0.00001);
        driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, false, NOW, 0.00001);
        driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.001);

        transactions.advance(created.booking().getId());

        DispatchStore.Offer offer = store.pendingForBooking(created.booking().getId()).orElseThrow();
        assertThat(offer.driverId()).isEqualTo(eligible.getId());
        assertThat(offer.expiresAt()).isEqualTo(offer.offeredAt().plusSeconds(15));
        assertThat(offer.offeredAt()).isEqualTo(NOW);
        Booking searching = bookings.findById(created.booking().getId()).orElseThrow();
        assertThat(searching.getStatus()).isEqualTo(BookingStatus.SEARCHING_DRIVER);
        assertThat(searching.getAssignedDriver()).isNull();
        assertThat(searching.getAssignedVehicle()).isNull();
        assertThatThrownBy(() -> jdbc.update("UPDATE bookings SET status='DRIVER_ACCEPTED' WHERE id=?",
                created.booking().getId())).isInstanceOf(DataIntegrityViolationException.class);
        assertThat(drivers.findById(eligible.getId()).orElseThrow().getOperatingStatus())
                .isEqualTo(DriverOperatingStatus.ONLINE);
        assertThat(jdbc.queryForObject("SELECT version FROM flyway_schema_history WHERE success=TRUE ORDER BY installed_rank DESC LIMIT 1", String.class))
                .isEqualTo("11");
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM pg_constraint WHERE conname='chk_offer_exact_lease'", Integer.class))
                .isEqualTo(1);
        for (String index : new String[]{"uq_offer_pending_booking", "uq_offer_pending_driver",
                "uq_offer_accepted_booking", "uq_bookings_active_driver", "idx_bookings_dispatch_due"}) {
            assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM pg_indexes WHERE indexname=?", Integer.class, index))
                    .isEqualTo(1);
        }
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM pg_indexes WHERE indexname='idx_driver_locations_current_location_gist'", Integer.class))
                .isEqualTo(1);
        Driver another = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.003);
        Long anotherVehicleId = jdbc.queryForObject("SELECT id FROM vehicles WHERE driver_id=? AND is_active=TRUE",
                Long.class, another.getId());
        assertThatThrownBy(() -> insertOffer(created.booking().getId(), another.getId(), anotherVehicleId))
                .isInstanceOf(DataIntegrityViolationException.class);
        Created anotherBooking = booking(VehicleType.MOTORBIKE);
        assertThatThrownBy(() -> insertOffer(anotherBooking.booking().getId(), eligible.getId(), offer.vehicleId()))
                .isInstanceOf(DataIntegrityViolationException.class);
        assertThatThrownBy(() -> insertOffer(anotherBooking.booking().getId(), another.getId(), offer.vehicleId()))
                .isInstanceOf(DataIntegrityViolationException.class);
    }

    @Test
    void noCandidateRemainsSearchingWithBoundedRetryUntilNearbyDriverArrives() {
        Created created = booking(VehicleType.MOTORBIKE);
        Driver outsideRadius = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.1);

        transactions.advance(created.booking().getId());

        assertThat(store.pendingForBooking(created.booking().getId())).isEmpty();
        assertThat(bookings.findById(created.booking().getId()).orElseThrow().getStatus())
                .isEqualTo(BookingStatus.SEARCHING_DRIVER);
        assertThat(jdbc.queryForObject("SELECT next_dispatch_at FROM bookings WHERE id=?",
                java.sql.Timestamp.class, created.booking().getId()).toInstant())
                .isEqualTo(NOW.plusSeconds(properties.getRetrySeconds()));
        assertThat(active(outsideRadius)).isEmpty();

        clock.set(NOW.plusSeconds(properties.getRetrySeconds()));
        Driver nearby = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, clock.instant(), 0.0001);
        transactions.advance(created.booking().getId());
        assertThat(active(nearby)).hasSize(1);
    }

    @Test
    void rejectionAndExpiryAdvanceSequentiallyWithoutRecyclingCandidates() {
        Created created = booking(VehicleType.MOTORBIKE);
        Driver first = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.0001);
        Driver second = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.0002);
        Driver third = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.0003);

        transactions.advance(created.booking().getId());
        DriverOfferResponse firstOffer = active(first).getFirst();
        offers.reject(first.getUser().getPublicId(), UserRole.DRIVER, firstOffer.offerPublicId());
        assertThat(active(first)).isEmpty();
        transactions.advance(created.booking().getId());
        DriverOfferResponse secondOffer = active(second).getFirst();
        assertThat(active(first)).isEmpty();
        clock.set(NOW.plusSeconds(15));
        assertThat(active(second)).isEmpty();
        assertThatThrownBy(() -> offers.accept(second.getUser().getPublicId(), UserRole.DRIVER,
                secondOffer.offerPublicId())).isInstanceOf(DomainException.class)
                .extracting(ex -> ((DomainException) ex).getCode()).isEqualTo("OFFER_EXPIRED");
        transactions.advance(created.booking().getId());
        assertThat(active(third)).hasSize(1);
        assertThat(jdbc.queryForObject("SELECT status FROM booking_driver_offers WHERE public_id=?",
                String.class, firstOffer.offerPublicId())).isEqualTo("REJECTED");
        assertThat(jdbc.queryForObject("SELECT status FROM booking_driver_offers WHERE public_id=?",
                String.class, secondOffer.offerPublicId())).isEqualTo("EXPIRED");
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM booking_driver_offers WHERE booking_id=? AND status='PENDING'",
                Integer.class, created.booking().getId())).isEqualTo(1);
        assertThat(bookings.findById(created.booking().getId()).orElseThrow().getStatus())
                .isEqualTo(BookingStatus.SEARCHING_DRIVER);
    }

    @Test
    void secureApiAcceptanceAndOriginalV10ReplayRemainCorrect() throws Exception {
        Created created = booking(VehicleType.MOTORBIKE);
        Driver selected = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.0001);
        Driver foreign = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.001);
        transactions.advance(created.booking().getId());
        DriverOfferResponse offer = active(selected).getFirst();
        String base = "/api/v1/drivers/me/offers";

        mvc.perform(get(base + "/active")).andExpect(status().isUnauthorized());
        mvc.perform(get(base + "/active").header("Authorization", bearer(created.customer())))
                .andExpect(status().isForbidden());
        mvc.perform(get(base + "/active").header("Authorization", bearer(foreign.getUser())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.length()").value(0));
        mvc.perform(get(base + "/active").header("Authorization", bearer(selected.getUser())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data[0].offerPublicId").value(offer.offerPublicId().toString()))
                .andExpect(jsonPath("$.data[0].finalFare").value(35400.00))
                .andExpect(jsonPath("$.data[0].driverId").doesNotExist());
        mvc.perform(post(base + "/" + offer.offerPublicId() + "/accept"))
                .andExpect(status().isUnauthorized());
        mvc.perform(post(base + "/" + offer.offerPublicId() + "/accept")
                .header("Authorization", bearer(created.customer()))).andExpect(status().isForbidden());
        mvc.perform(post(base + "/" + offer.offerPublicId() + "/accept")
                .header("Authorization", bearer(foreign.getUser()))).andExpect(status().isNotFound());
        mvc.perform(post(base + "/" + offer.offerPublicId() + "/reject")
                .header("Authorization", bearer(created.customer()))).andExpect(status().isForbidden());
        mvc.perform(post(base + "/" + offer.offerPublicId() + "/reject")
                .header("Authorization", bearer(foreign.getUser()))).andExpect(status().isNotFound());

        mvc.perform(post(base + "/" + offer.offerPublicId() + "/accept")
                .header("Authorization", bearer(selected.getUser())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.status").value("ACCEPTED"));
        mvc.perform(post(base + "/" + offer.offerPublicId() + "/accept")
                .header("Authorization", bearer(selected.getUser())))
                .andExpect(status().isConflict()).andExpect(jsonPath("$.code").value("OFFER_NOT_PENDING"));

        Booking accepted = bookings.findById(created.booking().getId()).orElseThrow();
        assertThat(accepted.getStatus()).isEqualTo(BookingStatus.DRIVER_ACCEPTED);
        assertThat(accepted.getAssignedDriver().getId()).isEqualTo(selected.getId());
        UUID acceptedVehiclePublicId = offerVehiclePublicId(offer.offerPublicId());
        assertThat(accepted.getDriverAcceptedAt()).isEqualTo(NOW);
        assertThat(accepted.getFinalFare()).isEqualTo(created.booking().getFinalFare());
        assertThat(accepted.getPricingSnapshot()).isEqualTo(created.booking().getPricingSnapshot());
        assertThat(drivers.findById(selected.getId()).orElseThrow().getOperatingStatus())
                .isEqualTo(DriverOperatingStatus.BUSY);
        mvc.perform(get("/api/v1/bookings/" + accepted.getPublicId())
                .header("Authorization", bearer(created.customer())))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.status").value("DRIVER_ACCEPTED"))
                .andExpect(jsonPath("$.data.driverPublicId").value(selected.getPublicId().toString()))
                .andExpect(jsonPath("$.data.vehiclePublicId").value(acceptedVehiclePublicId.toString()))
                .andExpect(jsonPath("$.data.assignedDriverId").doesNotExist());
        var replay = bookingService.create(created.customer().getPublicId(), UserRole.CUSTOMER,
                created.quote().getPublicId(), created.key());
        assertThat(replay.httpStatus()).isEqualTo(201);
        assertThat(replay.responseBody()).isEqualTo(created.originalBody());
    }

    @Test
    void simultaneousWorkersAndAcceptsCannotDuplicateAssignment() throws Exception {
        Created created = booking(VehicleType.MOTORBIKE);
        Driver selected = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.0001);
        race(() -> { transactions.advance(created.booking().getId()); return "done"; },
                () -> { transactions.advance(created.booking().getId()); return "done"; });
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM booking_driver_offers WHERE booking_id=?",
                Integer.class, created.booking().getId())).isEqualTo(1);
        UUID offerId = active(selected).getFirst().offerPublicId();

        List<String> results = race(() -> decision(() -> offers.accept(selected.getUser().getPublicId(),
                        UserRole.DRIVER, offerId)),
                () -> decision(() -> offers.accept(selected.getUser().getPublicId(), UserRole.DRIVER, offerId)));
        assertThat(results).containsExactlyInAnyOrder("ACCEPTED", "OFFER_NOT_PENDING");
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM booking_driver_offers WHERE booking_id=? AND status='ACCEPTED'",
                Integer.class, created.booking().getId())).isEqualTo(1);
        assertThat(bookings.findById(created.booking().getId()).orElseThrow().getAssignedDriver().getId())
                .isEqualTo(selected.getId());
    }

    @Test
    void pendingOfferBlocksSameDriverOnAnotherBookingAndAssignmentStaysUnique() throws Exception {
        Created first = booking(VehicleType.MOTORBIKE);
        Created second = booking(VehicleType.MOTORBIKE);
        Driver selected = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.0001);
        race(() -> { transactions.advance(first.booking().getId()); return "done"; },
                () -> { transactions.advance(second.booking().getId()); return "done"; });
        Long offeredBookingId = store.pendingForBooking(first.booking().getId()).isPresent()
                ? first.booking().getId() : second.booking().getId();
        Long waitingBookingId = offeredBookingId.equals(first.booking().getId())
                ? second.booking().getId() : first.booking().getId();
        assertThat(store.pendingForBooking(waitingBookingId)).isEmpty();
        assertThat(bookings.findById(waitingBookingId).orElseThrow().getStatus())
                .isEqualTo(BookingStatus.SEARCHING_DRIVER);
        offers.accept(selected.getUser().getPublicId(), UserRole.DRIVER,
                active(selected).getFirst().offerPublicId());
        jdbc.update("UPDATE drivers SET operating_status='ONLINE', version=version+1 WHERE id=?", selected.getId());
        clock.set(NOW.plusSeconds(5));
        transactions.advance(waitingBookingId);
        assertThat(store.pendingForBooking(waitingBookingId)).isEmpty();
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM bookings WHERE assigned_driver_id=? AND status='DRIVER_ACCEPTED'",
                Integer.class, selected.getId())).isEqualTo(1);
    }

    @Test
    void oldDriverCannotCompeteAfterSequentialReplacementIsAccepted() throws Exception {
        Created created = booking(VehicleType.MOTORBIKE);
        Driver first = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.0001);
        Driver second = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.0002);
        transactions.advance(created.booking().getId());
        UUID oldOffer = active(first).getFirst().offerPublicId();
        offers.reject(first.getUser().getPublicId(), UserRole.DRIVER, oldOffer);
        transactions.advance(created.booking().getId());
        UUID replacement = active(second).getFirst().offerPublicId();

        List<String> outcomes = race(() -> decision(() -> offers.accept(first.getUser().getPublicId(),
                        UserRole.DRIVER, oldOffer)),
                () -> decision(() -> offers.accept(second.getUser().getPublicId(), UserRole.DRIVER, replacement)));
        assertThat(outcomes).containsExactlyInAnyOrder("OFFER_NOT_PENDING", "ACCEPTED");
        assertThat(bookings.findById(created.booking().getId()).orElseThrow().getAssignedDriver().getId())
                .isEqualTo(second.getId());
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM booking_driver_offers WHERE booking_id=? AND status='ACCEPTED'",
                Integer.class, created.booking().getId())).isEqualTo(1);
    }

    @Test
    void ineligibleDriverOrVehicleCannotAcceptAndRollbackIsComplete() {
        Created first = booking(VehicleType.MOTORBIKE);
        Driver selected = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.0001);
        transactions.advance(first.booking().getId());
        UUID offerId = active(selected).getFirst().offerPublicId();
        jdbc.update("UPDATE drivers SET operating_status='OFFLINE', version=version+1 WHERE id=?", selected.getId());
        assertThatThrownBy(() -> offers.accept(selected.getUser().getPublicId(), UserRole.DRIVER, offerId))
                .isInstanceOf(DomainException.class)
                .extracting(ex -> ((DomainException) ex).getCode()).isEqualTo("DRIVER_UNAVAILABLE");
        assertThat(store.pendingForBooking(first.booking().getId())).isPresent();

        jdbc.update("UPDATE drivers SET operating_status='ONLINE', version=version+1 WHERE id=?", selected.getId());
        jdbc.update("UPDATE vehicles SET is_active=FALSE, version=version+1 WHERE id=?",
                store.pendingForBooking(first.booking().getId()).orElseThrow().vehicleId());
        assertThatThrownBy(() -> offers.accept(selected.getUser().getPublicId(), UserRole.DRIVER, offerId))
                .isInstanceOf(DomainException.class)
                .extracting(ex -> ((DomainException) ex).getCode()).isEqualTo("VEHICLE_UNAVAILABLE");
        assertThat(bookings.findById(first.booking().getId()).orElseThrow().getAssignedDriver()).isNull();
        assertThat(drivers.findById(selected.getId()).orElseThrow().getOperatingStatus())
                .isEqualTo(DriverOperatingStatus.ONLINE);
    }

    @Test
    void acceptanceFailureAfterOfferMutationRollsBackAllThreeRecords() {
        Created created = booking(VehicleType.MOTORBIKE);
        Driver selected = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.0001);
        transactions.advance(created.booking().getId());
        UUID offerId = active(selected).getFirst().offerPublicId();
        jdbc.execute("ALTER TABLE bookings ADD CONSTRAINT chk_v11_test_block_accept CHECK (status <> 'DRIVER_ACCEPTED') NOT VALID");
        try {
            assertThatThrownBy(() -> offers.accept(selected.getUser().getPublicId(), UserRole.DRIVER, offerId))
                    .isInstanceOf(DataIntegrityViolationException.class);
        } finally {
            jdbc.execute("ALTER TABLE bookings DROP CONSTRAINT chk_v11_test_block_accept");
        }
        assertThat(store.pendingForBooking(created.booking().getId())).isPresent();
        assertThat(bookings.findById(created.booking().getId()).orElseThrow().getStatus())
                .isEqualTo(BookingStatus.SEARCHING_DRIVER);
        assertThat(bookings.findById(created.booking().getId()).orElseThrow().getAssignedDriver()).isNull();
        assertThat(drivers.findById(selected.getId()).orElseThrow().getOperatingStatus())
                .isEqualTo(DriverOperatingStatus.ONLINE);
    }

    @Test
    void offerExpiringWhileAcceptanceWaitsForBookingLockCannotBeAccepted() throws Exception {
        Created created = booking(VehicleType.MOTORBIKE);
        Driver selected = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.0001);
        transactions.advance(created.booking().getId());
        UUID offerId = active(selected).getFirst().offerPublicId();
        ExecutorService executor = Executors.newSingleThreadExecutor();
        try (Connection holder = dataSource.getConnection()) {
            holder.setAutoCommit(false);
            int holderPid;
            try (PreparedStatement statement = holder.prepareStatement("SELECT pg_backend_pid()")) {
                try (var rows = statement.executeQuery()) { rows.next(); holderPid = rows.getInt(1); }
            }
            try (PreparedStatement statement = holder.prepareStatement("SELECT id FROM bookings WHERE id=? FOR UPDATE")) {
                statement.setLong(1, created.booking().getId());
                statement.executeQuery().close();
            }
            Future<String> waiting = executor.submit(() -> decision(() ->
                    offers.accept(selected.getUser().getPublicId(), UserRole.DRIVER, offerId)));
            try {
                awaitBlockedBy(holderPid);
                clock.set(NOW.plusSeconds(15));
                holder.commit();
                assertThat(waiting.get(10, TimeUnit.SECONDS)).isEqualTo("OFFER_EXPIRED");
            } finally { holder.rollback(); }
        } finally { executor.shutdownNow(); }
        assertThat(store.pendingForBooking(created.booking().getId())).isPresent();
        assertThat(bookings.findById(created.booking().getId()).orElseThrow().getStatus())
                .isEqualTo(BookingStatus.SEARCHING_DRIVER);
        assertThat(drivers.findById(selected.getId()).orElseThrow().getOperatingStatus())
                .isEqualTo(DriverOperatingStatus.ONLINE);
    }

    @Test
    void newlyConstructedCoordinatorRecoversDurableExpiredOffer() {
        Created created = booking(VehicleType.MOTORBIKE);
        Driver first = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.0001);
        Driver second = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW, 0.0002);
        transactions.advance(created.booking().getId());
        assertThat(active(first)).hasSize(1);
        clock.set(NOW.plusSeconds(15));
        jdbc.update("UPDATE bookings SET next_dispatch_at=? WHERE id<>? AND status IN ('REQUESTED','SEARCHING_DRIVER')",
                Timestamp.from(NOW.plusSeconds(3600)), created.booking().getId());
        DispatchCoordinator restarted = new DispatchCoordinator(store, transactions, properties, clock);

        assertThat(restarted.runBatch()).isEqualTo(1);
        assertThat(active(first)).isEmpty();
        assertThat(active(second)).hasSize(1);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM booking_driver_offers WHERE booking_id=?",
                Integer.class, created.booking().getId())).isEqualTo(2);
    }

    private Created booking(VehicleType type) {
        User customer = user(UserRole.CUSTOMER);
        RouteEstimate route = new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "TEST_ROUTER");
        Quote quote = quotes.saveAndFlush(new Quote(customer,
                new GeoCoordinate(new BigDecimal("21.0287"), new BigDecimal("105.8524")),
                new GeoCoordinate(new BigDecimal("21.0245"), new BigDecimal("105.8576")),
                type, route, pricing.calculate(type, route), clock.instant()));
        String key = UUID.randomUUID().toString();
        String body = bookingService.create(customer.getPublicId(), UserRole.CUSTOMER,
                quote.getPublicId(), key).responseBody();
        try {
            JsonNode data = mapper.readTree(body).path("data");
            Booking booking = bookings.findById(bookings.findOwned(UUID.fromString(data.path("bookingPublicId").asText()),
                    customer.getPublicId()).orElseThrow().getId()).orElseThrow();
            return new Created(customer, quote, booking, key, body);
        } catch (Exception ex) { throw new IllegalStateException(ex); }
    }

    private User user(UserRole role) {
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "dispatch-" + suffix + "@example.test", "hash", "Dispatch Test");
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private Driver driver(DriverApprovalStatus approval, DriverOperatingStatus operating,
                          VehicleType type, boolean activeVehicle, Instant locationTime, double latitudeOffset) {
        Driver driver = new Driver(user(UserRole.DRIVER), "DISPATCH-" + UUID.randomUUID());
        driver.setApprovalStatus(approval);
        driver.setOperatingStatus(approval == DriverApprovalStatus.APPROVED
                ? operating : DriverOperatingStatus.OFFLINE);
        driver = drivers.saveAndFlush(driver);
        testDriverIds.add(driver.getId());
        if (activeVehicle) {
            Vehicle vehicle = new Vehicle(driver, "D-" + UUID.randomUUID().toString().substring(0, 12),
                    type, "Test", "Test", "White");
            vehicle.setActive(true);
            vehicles.saveAndFlush(vehicle);
        }
        jdbc.update("""
                INSERT INTO driver_locations (driver_id, current_location, updated_at, version)
                VALUES (?, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?, 0)
                """, driver.getId(), LON, LAT + latitudeOffset, Timestamp.from(locationTime));
        return driver;
    }

    private List<DriverOfferResponse> active(Driver driver) {
        return offers.active(driver.getUser().getPublicId(), UserRole.DRIVER);
    }

    private UUID offerVehiclePublicId(UUID offerPublicId) {
        return jdbc.queryForObject("""
                SELECT v.public_id FROM booking_driver_offers o
                JOIN vehicles v ON v.id=o.vehicle_id WHERE o.public_id=?
                """, UUID.class, offerPublicId);
    }

    private void insertOffer(Long bookingId, Long driverId, Long vehicleId) {
        jdbc.update("""
                INSERT INTO booking_driver_offers
                    (public_id, booking_id, driver_id, vehicle_id, status, offered_at, expires_at)
                VALUES (?, ?, ?, ?, 'PENDING', ?, ?)
                """, UUID.randomUUID(), bookingId, driverId, vehicleId,
                Timestamp.from(NOW), Timestamp.from(NOW.plusSeconds(15)));
    }

    private String bearer(User user) { return "Bearer " + jwt.createAccessToken(user); }

    private String decision(Callable<?> action) throws Exception {
        try {
            action.call();
            return "ACCEPTED";
        } catch (DomainException ex) { return ex.getCode(); }
    }

    private List<String> race(Callable<String> first, Callable<String> second) throws Exception {
        ExecutorService executor = Executors.newFixedThreadPool(2);
        CountDownLatch ready = new CountDownLatch(2);
        CountDownLatch start = new CountDownLatch(1);
        try {
            Future<String> one = executor.submit(() -> { ready.countDown(); start.await(); return first.call(); });
            Future<String> two = executor.submit(() -> { ready.countDown(); start.await(); return second.call(); });
            assertThat(ready.await(5, TimeUnit.SECONDS)).isTrue();
            start.countDown();
            return List.of(one.get(10, TimeUnit.SECONDS), two.get(10, TimeUnit.SECONDS));
        } finally { executor.shutdownNow(); }
    }

    private void awaitBlockedBy(int holderPid) {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(4);
        while (System.nanoTime() < deadline) {
            Boolean blocked = jdbc.queryForObject("""
                    SELECT EXISTS (SELECT 1 FROM pg_stat_activity
                                   WHERE wait_event_type='Lock' AND ?=ANY(pg_blocking_pids(pid)))
                    """, Boolean.class, holderPid);
            if (Boolean.TRUE.equals(blocked)) return;
            LockSupport.parkNanos(TimeUnit.MILLISECONDS.toNanos(10));
        }
        throw new AssertionError("Acceptance did not wait for the Booking row lock");
    }

    private record Created(User customer, Quote quote, Booking booking, String key, String originalBody) {}

    static class MutableClock extends Clock {
        private final AtomicReference<Instant> now = new AtomicReference<>(NOW);
        void set(Instant value) { now.set(value); }
        @Override public ZoneId getZone() { return ZoneOffset.UTC; }
        @Override public Clock withZone(ZoneId zone) { return Clock.fixed(now.get(), zone); }
        @Override public Instant instant() { return now.get(); }
    }

    @TestConfiguration
    static class ClockConfiguration {
        @Bean @Primary MutableClock dispatchTestClock() { return new MutableClock(); }
    }
}
