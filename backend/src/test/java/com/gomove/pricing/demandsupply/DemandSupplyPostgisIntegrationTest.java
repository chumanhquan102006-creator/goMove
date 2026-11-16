package com.gomove.pricing.demandsupply;

import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.auth.domain.UserRole;
import com.gomove.booking.domain.Booking;
import com.gomove.booking.domain.BookingRepository;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.driver.domain.Driver;
import com.gomove.driver.domain.DriverApprovalStatus;
import com.gomove.driver.domain.DriverOperatingStatus;
import com.gomove.driver.domain.DriverRepository;
import com.gomove.location.domain.DriverLocationRepository;
import com.gomove.pricing.demandsupply.infrastructure.PostgresDemandSupplyProvider;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.Quote;
import com.gomove.pricing.domain.QuoteRepository;
import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.engine.PricingEngine;
import com.gomove.vehicle.domain.Vehicle;
import com.gomove.vehicle.domain.VehicleRepository;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Locale;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** PostgreSQL/PostGIS eligibility tests for aggregate-only demand and supply queries. */
class DemandSupplyPostgisIntegrationTest extends BaseIntegrationTest {
    private static final Instant NOW = Instant.parse("2030-01-01T01:00:00Z");
    private static final GeoCoordinate PICKUP = new GeoCoordinate(new BigDecimal("-30.0"), new BigDecimal("-80.0"));
    private static final GeoCoordinate SUPPLY_PICKUP = new GeoCoordinate(new BigDecimal("-35.0"), new BigDecimal("-75.0"));
    private static final GeoCoordinate BOUNDARY_PICKUP = new GeoCoordinate(new BigDecimal("-25.0"), new BigDecimal("-70.0"));
    private static final GeoCoordinate REGIONAL_PICKUP = new GeoCoordinate(new BigDecimal("-20.0"), new BigDecimal("-65.0"));
    private static final GeoCoordinate REMOTE_STALE_PICKUP = new GeoCoordinate(new BigDecimal("-10.0"), new BigDecimal("-55.0"));
    private static final GeoCoordinate DROPOFF = new GeoCoordinate(new BigDecimal("-30.01"), new BigDecimal("-80.01"));

    @Autowired PostgresDemandSupplyProvider provider;
    @Autowired UserRepository users;
    @Autowired DriverRepository drivers;
    @Autowired VehicleRepository vehicles;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired DriverLocationRepository locations;
    @Autowired PricingEngine pricing;
    @Autowired JdbcTemplate jdbc;
    @Autowired DemandSupplyPricingProperties properties;

    @BeforeEach
    void resetPricingProperties() {
        properties.setEnabled(false);
        properties.setPolicyVersion("DEMAND_SUPPLY_V1");
        properties.setRadiusMeters(5_000);
        properties.setLookback(java.time.Duration.ofMinutes(5));
        properties.setDriverLocationFreshnessSeconds(30);
        properties.setMinimumDemand(3);
        properties.setLowRatioThreshold(new BigDecimal("2.0"));
        properties.setHighRatioThreshold(new BigDecimal("4.0"));
        properties.setModerateMultiplier(new BigDecimal("1.1000"));
        properties.setHighMultiplier(new BigDecimal("1.2000"));
        properties.setMaximumMultiplier(new BigDecimal("1.2000"));
    }

    @AfterEach
    void restorePricingProperties() {
        resetPricingProperties();
    }

    @Test
    void demandCountsOnlyOutstandingUnassignedSameTypeRecentBookingsInsideRadius() {
        properties.setRadiusMeters(5_000);
        properties.setLookback(java.time.Duration.ofMinutes(5));
        Booking requested = booking(VehicleType.MOTORBIKE, PICKUP);
        setCreatedAt(requested, NOW.minusSeconds(60));
        Booking searching = booking(VehicleType.MOTORBIKE, PICKUP);
        jdbc.update("UPDATE bookings SET status='SEARCHING_DRIVER' WHERE id=?", searching.getId());
        setCreatedAt(searching, NOW.minusSeconds(120));

        Booking outsideRadius = booking(VehicleType.MOTORBIKE,
                new GeoCoordinate(new BigDecimal("-29.90"), PICKUP.longitude()));
        setCreatedAt(outsideRadius, NOW.minusSeconds(60));
        Booking old = booking(VehicleType.MOTORBIKE, PICKUP);
        setCreatedAt(old, NOW.minusSeconds(301));
        Booking future = booking(VehicleType.MOTORBIKE, PICKUP);
        setCreatedAt(future, NOW.plusSeconds(1));
        Booking otherVehicle = booking(VehicleType.CAR_4_SEAT, PICKUP);
        setCreatedAt(otherVehicle, NOW.minusSeconds(60));

        Driver assignedDriver = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.BUSY,
                VehicleType.MOTORBIKE, true, NOW.minusSeconds(5), PICKUP);
        Booking assigned = booking(VehicleType.MOTORBIKE, PICKUP);
        markAccepted(assigned, assignedDriver, NOW.minusSeconds(30));
        setCreatedAt(assigned, NOW.minusSeconds(60));

        Booking cancelled = booking(VehicleType.MOTORBIKE, PICKUP);
        jdbc.update("UPDATE bookings SET status='CANCELLED', cancelled_at=?, cancelled_by='CUSTOMER' WHERE id=?",
                ts(NOW.minusSeconds(10)), cancelled.getId());
        setCreatedAt(cancelled, NOW.minusSeconds(60));

        Booking completed = booking(VehicleType.MOTORBIKE, PICKUP);
        markCompleted(completed, assignedDriver, NOW.minusSeconds(60));
        setCreatedAt(completed, NOW.minusSeconds(100));

        DemandSupplyMetrics metrics = provider.snapshot(PICKUP, VehicleType.MOTORBIKE, NOW);

        assertThat(metrics.demandCount()).isEqualTo(2L);
        assertThat(metrics.availableDriverCount()).isZero();
    }

    @Test
    void supplyUsesPostgisRadiusDispatchEligibilityAndRejectsStaleGps() {
        properties.setRadiusMeters(5_000);
        properties.setDriverLocationFreshnessSeconds(30);
        driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW.minusSeconds(5), offset(SUPPLY_PICKUP, 0.001));
        Driver near = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW.minusSeconds(5), offset(SUPPLY_PICKUP, 0.001));
        driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW.minusSeconds(5), offset(SUPPLY_PICKUP, 0.10));
        driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.OFFLINE,
                VehicleType.MOTORBIKE, true, NOW.minusSeconds(5), SUPPLY_PICKUP);
        driver(DriverApprovalStatus.PENDING, DriverOperatingStatus.OFFLINE,
                VehicleType.MOTORBIKE, true, NOW.minusSeconds(5), SUPPLY_PICKUP);
        driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.BUSY,
                VehicleType.MOTORBIKE, true, NOW.minusSeconds(5), SUPPLY_PICKUP);
        driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.CAR_4_SEAT, true, NOW.minusSeconds(5), SUPPLY_PICKUP);
        Driver withoutActiveVehicle = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW.minusSeconds(5), SUPPLY_PICKUP);
        Vehicle inactiveVehicle = activeVehicle(withoutActiveVehicle);
        inactiveVehicle.setActive(false);
        vehicles.saveAndFlush(inactiveVehicle);
        Driver stale = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW.minusSeconds(60), SUPPLY_PICKUP);

        Booking offerBooking = booking(VehicleType.MOTORBIKE, SUPPLY_PICKUP);
        jdbc.update("""
                INSERT INTO booking_driver_offers
                    (public_id, booking_id, driver_id, vehicle_id, status, offered_at, expires_at, version)
                VALUES (?, ?, ?, ?, 'PENDING', ?, ?, 0)
                """, UUID.randomUUID(), offerBooking.getId(), near.getId(), activeVehicle(near).getId(),
                ts(NOW), ts(NOW.plusSeconds(15)));

        Driver assignedOnline = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW.minusSeconds(5), SUPPLY_PICKUP);
        Booking activeBooking = booking(VehicleType.MOTORBIKE, SUPPLY_PICKUP);
        markAccepted(activeBooking, assignedOnline, NOW.minusSeconds(10));

        DemandSupplyMetrics metrics = provider.snapshot(SUPPLY_PICKUP, VehicleType.MOTORBIKE, NOW);

        assertThat(metrics.availableDriverCount()).isEqualTo(1L);
        assertThat(metrics.eligibleDriverCount()).isEqualTo(2L);
        assertThat(metrics.freshEligibleDriverCount()).isEqualTo(1L);
        assertThat(metrics.status()).isEqualTo(DemandSupplyMetrics.Status.LOCATION_DATA_UNRELIABLE);
        assertThat(metrics.reason()).isEqualTo("STALE_OR_FUTURE_GPS_NEAR_PICKUP");
        assertThat(locations.countByDriverId(stale.getId())).isEqualTo(1L);
    }

    @Test
    void staleDriverGpsInAnotherRegionDoesNotSuppressLocalDemandPricing() {
        properties.setEnabled(true);
        for (int i = 0; i < 8; i++) {
            Booking demand = booking(VehicleType.MOTORBIKE, REGIONAL_PICKUP);
            setCreatedAt(demand, NOW.minusSeconds(30 + i));
        }
        driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW.minusSeconds(5), REGIONAL_PICKUP);
        driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW.minusSeconds(60), REMOTE_STALE_PICKUP);

        DemandSupplyMetrics metrics = provider.snapshot(REGIONAL_PICKUP, VehicleType.MOTORBIKE, NOW);
        var evaluation = new DemandSupplyPricingPolicy(properties).evaluate(NOW, metrics);

        assertThat(metrics.demandCount()).isEqualTo(8L);
        assertThat(metrics.availableDriverCount()).isEqualTo(1L);
        assertThat(metrics.eligibleDriverCount()).isEqualTo(1L);
        assertThat(metrics.freshEligibleDriverCount()).isEqualTo(1L);
        assertThat(metrics.status()).isEqualTo(DemandSupplyMetrics.Status.AVAILABLE);
        assertThat(evaluation.requestedMultiplier()).isEqualByComparingTo("1.2000");
        assertThat(evaluation.reason()).isEqualTo("HIGH_DEMAND_SUPPLY_RATIO");
    }

    @Test
    void queryUsesOneEvaluationTimestampForBothDemandAndGpsFreshness() {
        properties.setLookback(java.time.Duration.ofSeconds(20));
        properties.setDriverLocationFreshnessSeconds(30);
        Booking demand = booking(VehicleType.MOTORBIKE, BOUNDARY_PICKUP);
        setCreatedAt(demand, NOW.minusSeconds(20));
        driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE,
                VehicleType.MOTORBIKE, true, NOW.minusSeconds(30), BOUNDARY_PICKUP);

        DemandSupplyMetrics atBoundary = provider.snapshot(BOUNDARY_PICKUP, VehicleType.MOTORBIKE, NOW);
        DemandSupplyMetrics justAfterBoundary = provider.snapshot(BOUNDARY_PICKUP, VehicleType.MOTORBIKE,
                NOW.plusNanos(1_000));

        assertThat(atBoundary.demandCount()).isEqualTo(1L);
        assertThat(atBoundary.availableDriverCount()).isEqualTo(1L);
        assertThat(justAfterBoundary.demandCount()).isZero();
        assertThat(justAfterBoundary.availableDriverCount()).isZero();
        assertThat(justAfterBoundary.status()).isEqualTo(DemandSupplyMetrics.Status.LOCATION_DATA_UNRELIABLE);
    }

    @Test
    void flywayV19CreatesExpectedPartialBookingPickupGistIndex() {
        Boolean migrationApplied = jdbc.queryForObject("""
                SELECT EXISTS (
                    SELECT 1 FROM flyway_schema_history
                    WHERE version = '19' AND success = TRUE
                )
                """, Boolean.class);
        IndexMetadata metadata = jdbc.queryForObject("""
                SELECT am.amname AS access_method,
                       pg_get_indexdef(i.indexrelid) AS definition,
                       pg_get_expr(i.indpred, i.indrelid) AS predicate,
                       i.indisvalid AS valid,
                       i.indisready AS ready
                FROM pg_index i
                JOIN pg_class idx ON idx.oid = i.indexrelid
                JOIN pg_am am ON am.oid = idx.relam
                WHERE idx.relname = ?
                """, (rs, rowNum) -> new IndexMetadata(
                rs.getString("access_method"), rs.getString("definition"), rs.getString("predicate"),
                rs.getBoolean("valid"), rs.getBoolean("ready")), INDEX_NAME);

        assertThat(migrationApplied).isTrue();
        assertThat(metadata).isNotNull();
        assertThat(metadata.accessMethod()).isEqualTo("gist");
        assertThat(metadata.definition().toLowerCase(Locale.ROOT))
                .contains("using gist (pickup_location)");
        assertThat(metadata.predicate().toLowerCase(Locale.ROOT))
                .contains("requested", "searching_driver", "assigned_driver_id is null",
                        "assigned_vehicle_id is null");
        assertThat(metadata.valid()).isTrue();
        assertThat(metadata.ready()).isTrue();
    }

    @Test
    void partialPickupIndexReducesCandidateRowsForDemandQuery() {
        properties.setLookback(Duration.ofMinutes(5));
        properties.setRadiusMeters(5_000);
        User customer = user(UserRole.CUSTOMER);
        Driver historicalDriver = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.OFFLINE,
                VehicleType.MOTORBIKE, true, NOW, PICKUP);
        seedExplainDistribution(customer.getId(), historicalDriver.getId(), activeVehicle(historicalDriver).getId());
        jdbc.execute("ANALYZE bookings");

        Instant evaluatedAt = Instant.now().plusSeconds(1);
        String baselinePlan;
        jdbc.execute("DROP INDEX " + INDEX_NAME);
        try {
            jdbc.execute("ANALYZE bookings");
            baselinePlan = explainDemandQuery(evaluatedAt);
        } finally {
            jdbc.execute(INDEX_DDL);
            jdbc.execute("ANALYZE bookings");
        }
        String indexedPlan = explainDemandQuery(evaluatedAt);

        System.out.println("[M2B-EXPLAIN] demand query baseline without partial GiST index:\n" + baselinePlan);
        System.out.println("[M2B-EXPLAIN] demand query with partial GiST index:\n" + indexedPlan);
        assertThat(indexedPlan).contains(INDEX_NAME);
        assertThat(countDemand(evaluatedAt)).isEqualTo(20L);
    }

    private static final String INDEX_NAME = "idx_bookings_m2b_open_pickup_gist";
    private static final String INDEX_DDL = """
            CREATE INDEX idx_bookings_m2b_open_pickup_gist
                ON bookings USING GIST (pickup_location)
                WHERE status IN ('REQUESTED', 'SEARCHING_DRIVER')
                  AND assigned_driver_id IS NULL
                  AND assigned_vehicle_id IS NULL
            """;
    private static final String DEMAND_QUERY = """
            SELECT COUNT(*)
            FROM bookings b
            WHERE b.status IN ('REQUESTED', 'SEARCHING_DRIVER')
              AND b.assigned_driver_id IS NULL
              AND b.assigned_vehicle_id IS NULL
              AND b.vehicle_type = ?
              AND b.created_at >= ? AND b.created_at <= ?
              AND ST_DWithin(
                    b.pickup_location,
                    ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography,
                    ?
              )
            """;

    private String explainDemandQuery(Instant evaluatedAt) {
        List<String> plan = jdbc.query("EXPLAIN (ANALYZE, BUFFERS) " + DEMAND_QUERY,
                (rs, rowNum) -> rs.getString(1), VehicleType.MOTORBIKE.name(),
                ts(evaluatedAt.minus(properties.getLookback())), ts(evaluatedAt),
                PICKUP.longitude().doubleValue(), PICKUP.latitude().doubleValue(), properties.getRadiusMeters());
        return String.join(System.lineSeparator(), plan);
    }

    private long countDemand(Instant evaluatedAt) {
        Long count = jdbc.queryForObject(DEMAND_QUERY, Long.class, VehicleType.MOTORBIKE.name(),
                ts(evaluatedAt.minus(properties.getLookback())), ts(evaluatedAt),
                PICKUP.longitude().doubleValue(), PICKUP.latitude().doubleValue(), properties.getRadiusMeters());
        return count == null ? 0L : count;
    }

    private void seedExplainDistribution(Long customerId, Long driverId, Long vehicleId) {
        jdbc.update("""
                WITH sample_rows AS (
                    SELECT n,
                           CASE WHEN n <= 30000 THEN CURRENT_TIMESTAMP - INTERVAL '30 days'
                                WHEN n % 4 = 0 THEN CURRENT_TIMESTAMP - INTERVAL '10 minutes'
                                ELSE CURRENT_TIMESTAMP - INTERVAL '30 seconds' END AS booking_created_at,
                           CASE WHEN n > 30000 AND n % 100 = 1
                                THEN ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography
                                WHEN n % 2 = 0
                                THEN ST_SetSRID(ST_MakePoint(100 + (n % 50), 40 + (n % 20)), 4326)::geography
                                ELSE ST_SetSRID(ST_MakePoint(-170 + (n % 50), -80 + (n % 20)), 4326)::geography
                           END AS pickup
                    FROM generate_series(1, 32000) n
                ), inserted_quotes AS (
                    INSERT INTO quotes (
                        public_id, customer_id, pickup_location, dropoff_location,
                        distance_meters, duration_seconds, routing_provider, vehicle_type, currency_code,
                        base_fare, distance_fare, time_fare, surcharge, surge_multiplier, surge_amount,
                        discount_amount, rounding_adjustment, final_fare, pricing_engine_version,
                        pricing_snapshot, status, issued_at, expires_at, consumed_at, created_at, updated_at
                    )
                    SELECT gen_random_uuid(), ?, sample_rows.pickup,
                           ST_SetSRID(ST_MakePoint(-80.01, -30.01), 4326)::geography,
                           1000, 60, 'M2B_EXPLAIN', 'MOTORBIKE', 'VND',
                           1, 0, 0, 0, 1, 0, 0, 0, 1, 'M2B_EXPLAIN', '{}'::jsonb,
                           'CONSUMED', sample_rows.booking_created_at - INTERVAL '20 seconds',
                           sample_rows.booking_created_at + INTERVAL '40 seconds',
                           sample_rows.booking_created_at - INTERVAL '10 seconds',
                           sample_rows.booking_created_at, sample_rows.booking_created_at
                    FROM sample_rows
                    RETURNING id, created_at, pickup_location
                )
                INSERT INTO bookings (
                    public_id, customer_id, quote_id, status, pickup_location, dropoff_location,
                    distance_meters, duration_seconds, routing_provider, vehicle_type, currency_code,
                    final_fare, pricing_engine_version, pricing_snapshot, created_at, updated_at,
                    assigned_driver_id, assigned_vehicle_id, driver_accepted_at, next_dispatch_at,
                    driver_arrived_at, passenger_onboard_at, trip_started_at, trip_completed_at,
                    driver_released_at
                )
                SELECT gen_random_uuid(), ?, q.id,
                       CASE WHEN q.created_at < CURRENT_TIMESTAMP - INTERVAL '1 day'
                            THEN 'COMPLETED' ELSE 'REQUESTED' END,
                       q.pickup_location, ST_SetSRID(ST_MakePoint(-80.01, -30.01), 4326)::geography,
                       1000, 60, 'M2B_EXPLAIN', 'MOTORBIKE', 'VND', 1, 'M2B_EXPLAIN', '{}'::jsonb,
                       q.created_at, q.created_at,
                       CASE WHEN q.created_at < CURRENT_TIMESTAMP - INTERVAL '1 day' THEN ? ELSE NULL END,
                       CASE WHEN q.created_at < CURRENT_TIMESTAMP - INTERVAL '1 day' THEN ? ELSE NULL END,
                       CASE WHEN q.created_at < CURRENT_TIMESTAMP - INTERVAL '1 day'
                            THEN q.created_at + INTERVAL '5 seconds' ELSE NULL END,
                       q.created_at,
                       CASE WHEN q.created_at < CURRENT_TIMESTAMP - INTERVAL '1 day'
                            THEN q.created_at + INTERVAL '10 seconds' ELSE NULL END,
                       CASE WHEN q.created_at < CURRENT_TIMESTAMP - INTERVAL '1 day'
                            THEN q.created_at + INTERVAL '20 seconds' ELSE NULL END,
                       CASE WHEN q.created_at < CURRENT_TIMESTAMP - INTERVAL '1 day'
                            THEN q.created_at + INTERVAL '30 seconds' ELSE NULL END,
                       CASE WHEN q.created_at < CURRENT_TIMESTAMP - INTERVAL '1 day'
                            THEN q.created_at + INTERVAL '40 seconds' ELSE NULL END,
                       CASE WHEN q.created_at < CURRENT_TIMESTAMP - INTERVAL '1 day'
                            THEN q.created_at + INTERVAL '50 seconds' ELSE NULL END
                FROM inserted_quotes q
                """, PICKUP.longitude().doubleValue(), PICKUP.latitude().doubleValue(), customerId, customerId,
                driverId, vehicleId);
    }

    private Booking booking(VehicleType type, GeoCoordinate pickup) {
        User customer = user(UserRole.CUSTOMER);
        RouteEstimate route = new RouteEstimate(new BigDecimal("1000"), new BigDecimal("60"), "TEST_ROUTER");
        Quote quote = quotes.saveAndFlush(new Quote(customer, pickup, DROPOFF, type, route,
                pricing.calculate(type, route), NOW.minusSeconds(60)));
        return bookings.saveAndFlush(new Booking(customer, quote));
    }

    private Driver driver(DriverApprovalStatus approval, DriverOperatingStatus operating,
                          VehicleType type, boolean active, Instant locationTime, GeoCoordinate coordinate) {
        Driver driver = new Driver(user(UserRole.DRIVER), "DS-" + UUID.randomUUID());
        driver.setApprovalStatus(approval);
        driver.setOperatingStatus(operating);
        driver = drivers.saveAndFlush(driver);
        Vehicle vehicle = new Vehicle(driver, "D" + UUID.randomUUID().toString().replace("-", "").substring(0, 18),
                type, "Test", "Test", "Blue");
        vehicle.setActive(active);
        vehicles.saveAndFlush(vehicle);
        jdbc.update("""
                INSERT INTO driver_locations (driver_id, current_location, updated_at, version)
                VALUES (?, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?, 0)
                """, driver.getId(), coordinate.longitude().doubleValue(), coordinate.latitude().doubleValue(),
                ts(locationTime));
        return driver;
    }

    private User user(UserRole role) {
        String suffix = UUID.randomUUID().toString().substring(0, 10);
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "m2b-" + suffix + "@example.test", "test-hash", "M2B Test");
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private Vehicle activeVehicle(Driver driver) {
        return vehicles.findByDriverIdAndIsActiveTrue(driver.getId()).orElseThrow();
    }

    private void markAccepted(Booking booking, Driver driver, Instant acceptedAt) {
        jdbc.update("""
                UPDATE bookings SET status='DRIVER_ACCEPTED', assigned_driver_id=?, assigned_vehicle_id=?,
                    driver_accepted_at=? WHERE id=?
                """, driver.getId(), activeVehicle(driver).getId(), ts(acceptedAt), booking.getId());
    }

    private void markCompleted(Booking booking, Driver driver, Instant acceptedAt) {
        jdbc.update("""
                UPDATE bookings SET status='COMPLETED', assigned_driver_id=?, assigned_vehicle_id=?,
                    driver_accepted_at=?, driver_arrived_at=?, passenger_onboard_at=?, trip_started_at=?,
                    trip_completed_at=?, driver_released_at=? WHERE id=?
                """, driver.getId(), activeVehicle(driver).getId(), ts(acceptedAt), ts(acceptedAt.plusSeconds(1)),
                ts(acceptedAt.plusSeconds(2)), ts(acceptedAt.plusSeconds(3)), ts(acceptedAt.plusSeconds(4)),
                ts(acceptedAt.plusSeconds(5)), booking.getId());
    }

    private void setCreatedAt(Booking booking, Instant createdAt) {
        jdbc.update("UPDATE bookings SET created_at=?, updated_at=? WHERE id=?",
                ts(createdAt), ts(createdAt), booking.getId());
    }

    private GeoCoordinate offset(GeoCoordinate coordinate, double latitude) {
        return new GeoCoordinate(coordinate.latitude().add(BigDecimal.valueOf(latitude)), coordinate.longitude());
    }

    private Timestamp ts(Instant instant) { return Timestamp.from(instant); }

    private record IndexMetadata(String accessMethod, String definition, String predicate,
                                 boolean valid, boolean ready) { }
}
