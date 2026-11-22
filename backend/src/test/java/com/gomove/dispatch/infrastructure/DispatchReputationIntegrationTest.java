package com.gomove.dispatch.infrastructure;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.auth.domain.*;
import com.gomove.booking.domain.*;
import com.gomove.booking.service.BookingApplicationService;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.common.exception.DomainException;
import com.gomove.dispatch.service.*;
import com.gomove.driver.domain.*;
import com.gomove.pricing.domain.*;
import com.gomove.pricing.engine.PricingEngine;
import com.gomove.vehicle.domain.*;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.TestPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.Timestamp;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;

@TestPropertySource(properties = "gomove.dispatch.reputation-tie-break-enabled=true")
@Import(DispatchReputationIntegrationTest.ClockConfiguration.class)
class DispatchReputationIntegrationTest extends BaseIntegrationTest {
    private static final Instant NOW = Instant.parse("2030-01-01T01:00:00Z");
    private static final double LAT = 21.0287;
    private static final double LON = 105.8524;
    @Autowired JdbcTemplate jdbc;
    @Autowired DataSource dataSource;
    @Autowired UserRepository users;
    @Autowired DriverRepository drivers;
    @Autowired VehicleRepository vehicles;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired BookingApplicationService bookingService;
    @Autowired PricingEngine pricing;
    @Autowired ObjectMapper mapper;
    @Autowired DispatchStore store;
    @Autowired DispatchTransactionService dispatch;
    @Autowired DriverOfferService offers;
    @Autowired DispatchProperties properties;
    @Autowired PlatformTransactionManager transactionManager;
    @Autowired TestClock clock;
    private final List<Long> fixtureDrivers = new ArrayList<>();

    @BeforeEach void configure() {
        clock.now.set(NOW);
        properties.setReputationTieBreakEnabled(true);
        properties.setNearEqualMeters(50);
    }

    @AfterEach void isolateLocations() {
        for (Long id : fixtureDrivers) jdbc.update(
                "UPDATE driver_locations SET updated_at=? WHERE driver_id=?", Timestamp.from(Instant.EPOCH), id);
    }

    @Test void equalDistancePrefersBetterReputation() {
        Driver low = driver(.0001);
        Driver high = driver(.0001);
        ratings(low, 1, 3);
        ratings(high, 1, 5);
        assertOffered(booking(), high);
    }

    @Test void withinFiftyMetersCanPreferReputation() {
        Driver near = driver(.0001);
        Driver better = driver(.0004); // About 33m farther, inside the band.
        ratings(better, 1, 5);
        assertOffered(booking(), better);
        assertThat(store.hasActiveAssignment(near.getId())).isFalse();
    }

    @Test void outsideFiftyMetersCannotBuyPriorityWithReputation() {
        Driver near = driver(.0001);
        Driver far = driver(.0007); // About 66m farther, outside the band.
        ratings(near, 1, 1);
        ratings(far, 5, 5);
        assertOffered(booking(), near);
    }

    @Test void oneFiveStarRatingDoesNotBeatEstablishedFourPointNine() {
        Driver newcomer = driver(.0001);
        Driver established = driver(.0001);
        ratings(newcomer, 1, 5); // 45/11 = 4.0909...
        ratings(established, 90, 5);
        ratings(established, 10, 4); // (490+40)/110 = 4.8181...
        assertOffered(booking(), established);
    }

    @Test void unratedDriverHasNeutralFourRatherThanZero() {
        Driver rated = driver(.0001);
        Driver unrated = driver(.0002);
        ratings(rated, 1, 3);
        assertOffered(booking(), unrated);
    }

    @Test void equalScoresUseRealDistanceThenDriverId() {
        Driver lowerIdButFarther = driver(.0002);
        Driver near = driver(.0001);
        Driver sameDistanceHigherId = driver(.0001);
        ratings(lowerIdButFarther, 1, 4);
        ratings(near, 2, 4);
        assertThat(sameDistanceHigherId.getId()).isGreaterThan(near.getId());
        assertOffered(booking(), near); // All scores are exactly 4, including the unrated driver.
    }

    @Test void ineligibleDriversCannotDefineTheMinimumOrWin() {
        Driver busy = driver(0);
        Driver offline = driver(0);
        Driver stale = driver(0);
        Driver unapproved = driver(0);
        Driver inactive = driver(0);
        Driver wrongType = driver(0);
        jdbc.update("UPDATE drivers SET operating_status='BUSY' WHERE id=?", busy.getId());
        jdbc.update("UPDATE drivers SET operating_status='OFFLINE' WHERE id=?", offline.getId());
        jdbc.update("UPDATE driver_locations SET updated_at=? WHERE driver_id=?",
                Timestamp.from(NOW.minusSeconds(31)), stale.getId());
        jdbc.update("UPDATE drivers SET operating_status='OFFLINE', approval_status='PENDING' WHERE id=?",
                unapproved.getId());
        jdbc.update("UPDATE vehicles SET is_active=false WHERE driver_id=?", inactive.getId());
        jdbc.update("UPDATE vehicles SET vehicle_type='CAR_4_SEAT' WHERE driver_id=?", wrongType.getId());
        Driver eligible = driver(.001); // >50m from the excluded drivers: min must be computed AFTER eligibility.
        assertOffered(booking(), eligible);
    }

    @Test void pendingOfferAndUnreleasedAssignmentStillExcludeDriver() {
        Driver preferred = driver(.0001);
        ratings(preferred, 1, 5);
        Booking first = booking();
        assertOffered(first, preferred);
        Driver fallback = driver(.0002);
        Booking second = booking();
        assertOffered(second, fallback); // Preferred already has another PENDING offer.
        var offer = store.pendingForBooking(first.getId()).orElseThrow();
        UUID publicId = offerPublicId(offer.id());
        offers.accept(preferred.getUser().getPublicId(), UserRole.DRIVER, publicId);
        jdbc.update("UPDATE drivers SET operating_status='ONLINE', version=version+1 WHERE id=?", preferred.getId());
        Booking third = booking();
        dispatch.advance(third.getId());
        assertThat(store.pendingForBooking(third.getId())).isEmpty(); // Assignment + fallback's pending offer.
    }

    @Test void rejectionAndStrictFifteenSecondExpiryRecomputeCandidatesWithoutReinviting() {
        Driver best = driver(.0002);
        Driver remaining = driver(.0001);
        Driver moved = driver(.003);
        ratings(best, 1, 5);
        ratings(remaining, 1, 3);
        Booking booking = booking();
        assertOffered(booking, best);
        var first = store.pendingForBooking(booking.getId()).orElseThrow();
        assertThat(first.expiresAt()).isEqualTo(NOW.plusSeconds(15));
        offers.reject(best.getUser().getPublicId(), UserRole.DRIVER, offerPublicId(first.id()));
        jdbc.update("UPDATE driver_locations SET current_location=ST_SetSRID(ST_MakePoint(?, ?),4326)::geography WHERE driver_id=?",
                LON, LAT + .00001, moved.getId());
        assertOffered(booking, moved); // Re-read position; previous best must not be offered again.
        clock.now.set(NOW.plusSeconds(15));
        assertOffered(booking, remaining); // Strict expiry at the deadline, not after it.
        assertThat(jdbc.queryForList("SELECT status FROM booking_driver_offers WHERE booking_id=? ORDER BY id",
                String.class, booking.getId())).containsExactly("REJECTED", "EXPIRED", "PENDING");
    }

    @Test void reputationWorkersAndConcurrentAcceptsCannotDuplicateAssignment() throws Exception {
        Driver selected = driver(.0001);
        Booking booking = booking();
        race(() -> { dispatch.advance(booking.getId()); return "done"; },
                () -> { dispatch.advance(booking.getId()); return "done"; });
        assertThat(jdbc.queryForObject("SELECT count(*) FROM booking_driver_offers WHERE booking_id=?",
                Integer.class, booking.getId())).isEqualTo(1);
        UUID offer = offerPublicId(store.pendingForBooking(booking.getId()).orElseThrow().id());
        assertThat(race(() -> accept(selected, offer), () -> accept(selected, offer)))
                .containsExactlyInAnyOrder("ACCEPTED", "OFFER_NOT_PENDING");
        assertThat(bookings.findById(booking.getId()).orElseThrow().getAssignedDriver().getId())
                .isEqualTo(selected.getId());
    }

    @Test void flagOffKeepsDistanceFirstDespiteMuchBetterReputation() {
        properties.setReputationTieBreakEnabled(false);
        Driver near = driver(.0001);
        Driver better = driver(.0002);
        ratings(near, 1, 1);
        ratings(better, 3, 5);
        assertOffered(booking(), near);
    }

    @Test void lockedNearestGroupDoesNotExpandBandToFartherDrivers() throws Exception {
        Driver nearest = driver(.0001);
        driver(.001);
        Booking booking = booking();
        try (Connection holder = dataSource.getConnection()) {
            holder.setAutoCommit(false);
            try (var statement = holder.prepareStatement("SELECT id FROM drivers WHERE id=? FOR UPDATE")) {
                statement.setLong(1, nearest.getId());
                statement.executeQuery().close();
            }
            dispatch.advance(booking.getId());
            assertThat(store.pendingForBooking(booking.getId())).isEmpty();
            holder.commit();
        }
        assertOffered(booking, nearest);
    }

    @Test void planRestrictsRatingAggregationToNearGroup() throws Exception {
        Driver first = driver(.0001);
        Driver second = driver(.0002);
        Driver outside = driver(.001);
        ratings(first, 1, 5);
        ratings(second, 1, 4);
        ratings(outside, 1, 5);
        Booking booking = booking();
        JsonNode plan = new TransactionTemplate(transactionManager).execute(status -> {
            try {
                String json = jdbc.queryForObject("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) "
                                + DispatchStore.REPUTATION_CANDIDATE_SQL, String.class,
                        5000, booking.getId(), Timestamp.from(NOW.minusSeconds(30)), 50);
                return mapper.readTree(json);
            } catch (Exception ex) { throw new IllegalStateException(ex); }
        });
        List<JsonNode> ratingScans = new ArrayList<>();
        findRatingScans(plan, ratingScans);
        assertThat(ratingScans).isNotEmpty();
        assertThat(ratingScans).allSatisfy(node -> {
            assertThat(node.path("Actual Loops").asInt()).isEqualTo(2);
        });
        Files.createDirectories(Path.of("target"));
        Files.writeString(Path.of("target/dispatch-reputation-plan.json"), mapper.writerWithDefaultPrettyPrinter().writeValueAsString(plan));
    }

    private void findRatingScans(JsonNode node, List<JsonNode> scans) {
        if (node.isObject() && "trip_ratings".equals(node.path("Relation Name").asText())) scans.add(node);
        for (JsonNode child : node) findRatingScans(child, scans);
    }

    private void assertOffered(Booking booking, Driver driver) {
        dispatch.advance(booking.getId());
        assertThat(store.pendingForBooking(booking.getId()).orElseThrow().driverId()).isEqualTo(driver.getId());
        assertThat(jdbc.queryForObject("SELECT count(*) FROM booking_driver_offers WHERE booking_id=? AND status='PENDING'",
                Integer.class, booking.getId())).isEqualTo(1);
    }

    private User user(UserRole role) {
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "reputation-" + UUID.randomUUID() + "@example.test", "hash", "Reputation Test");
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private Driver driver(double offset) {
        Driver driver = new Driver(user(UserRole.DRIVER), "REP-" + UUID.randomUUID());
        driver.setApprovalStatus(DriverApprovalStatus.APPROVED);
        driver.setOperatingStatus(DriverOperatingStatus.ONLINE);
        driver = drivers.saveAndFlush(driver);
        Vehicle vehicle = new Vehicle(driver, "R-" + UUID.randomUUID().toString().substring(0, 12),
                VehicleType.MOTORBIKE, "Test", "Test", "White");
        vehicle.setActive(true);
        vehicles.saveAndFlush(vehicle);
        jdbc.update("INSERT INTO driver_locations(driver_id,current_location,updated_at,version) VALUES (?,ST_SetSRID(ST_MakePoint(?,?),4326)::geography,?,0)",
                driver.getId(), LON, LAT + offset, Timestamp.from(NOW));
        fixtureDrivers.add(driver.getId());
        return driver;
    }

    private Booking booking() {
        User customer = user(UserRole.CUSTOMER);
        RouteEstimate route = new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "TEST_ROUTER");
        Quote quote = quotes.saveAndFlush(new Quote(customer,
                new GeoCoordinate(BigDecimal.valueOf(LAT), BigDecimal.valueOf(LON)),
                new GeoCoordinate(new BigDecimal("21.0245"), new BigDecimal("105.8576")),
                VehicleType.MOTORBIKE, route, pricing.calculate(VehicleType.MOTORBIKE, route), clock.instant()));
        try {
            String body = bookingService.create(customer.getPublicId(), UserRole.CUSTOMER,
                    quote.getPublicId(), UUID.randomUUID().toString()).responseBody();
            UUID id = UUID.fromString(mapper.readTree(body).path("data").path("bookingPublicId").asText());
            return bookings.findOwned(id, customer.getPublicId()).orElseThrow();
        } catch (Exception ex) { throw new IllegalStateException(ex); }
    }

    private void ratings(Driver driver, int count, int stars) {
        Long vehicle = jdbc.queryForObject("SELECT id FROM vehicles WHERE driver_id=? AND is_active", Long.class, driver.getId());
        for (int i = 0; i < count; i++) {
            Booking booking = booking();
            jdbc.update("""
                    UPDATE bookings SET status='COMPLETED', assigned_driver_id=?, assigned_vehicle_id=?,
                        driver_accepted_at=?, driver_arrived_at=?, passenger_onboard_at=?, trip_started_at=?,
                        trip_completed_at=?, driver_released_at=?, version=version+1 WHERE id=?
                    """, driver.getId(), vehicle, Timestamp.from(NOW), Timestamp.from(NOW), Timestamp.from(NOW),
                    Timestamp.from(NOW), Timestamp.from(NOW), Timestamp.from(NOW), booking.getId());
            jdbc.update("INSERT INTO trip_ratings(public_id,booking_id,customer_id,driver_id,stars) VALUES (?,?,?,?,?)",
                    UUID.randomUUID(), booking.getId(), booking.getCustomer().getId(), driver.getId(), stars);
        }
    }

    private UUID offerPublicId(long id) {
        return jdbc.queryForObject("SELECT public_id FROM booking_driver_offers WHERE id=?", UUID.class, id);
    }

    private String accept(Driver driver, UUID offer) {
        try { offers.accept(driver.getUser().getPublicId(), UserRole.DRIVER, offer); return "ACCEPTED"; }
        catch (DomainException ex) { return ex.getCode(); }
    }

    private List<String> race(Callable<String> first, Callable<String> second) throws Exception {
        var executor = Executors.newFixedThreadPool(2);
        var ready = new CountDownLatch(2);
        var start = new CountDownLatch(1);
        try {
            Future<String> one = executor.submit(() -> { ready.countDown(); start.await(); return first.call(); });
            Future<String> two = executor.submit(() -> { ready.countDown(); start.await(); return second.call(); });
            assertThat(ready.await(5, TimeUnit.SECONDS)).isTrue();
            start.countDown();
            return List.of(one.get(10, TimeUnit.SECONDS), two.get(10, TimeUnit.SECONDS));
        } finally { executor.shutdownNow(); }
    }

    static class TestClock extends Clock {
        final AtomicReference<Instant> now = new AtomicReference<>(NOW);
        @Override public ZoneId getZone() { return ZoneOffset.UTC; }
        @Override public Clock withZone(ZoneId zone) { return Clock.fixed(now.get(), zone); }
        @Override public Instant instant() { return now.get(); }
    }

    @TestConfiguration static class ClockConfiguration {
        @Bean @Primary TestClock reputationClock() { return new TestClock(); }
    }
}
