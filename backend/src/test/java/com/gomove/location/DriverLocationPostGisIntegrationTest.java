package com.gomove.location;

import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.auth.domain.UserRole;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.driver.domain.Driver;
import com.gomove.driver.domain.DriverApprovalStatus;
import com.gomove.driver.domain.DriverOperatingStatus;
import com.gomove.driver.domain.DriverRepository;
import com.gomove.location.domain.DriverLocation;
import com.gomove.location.domain.DriverLocationRepository;
import com.gomove.location.service.DriverLocationService;
import com.gomove.location.service.NearbyDriverResult;
import com.gomove.vehicle.domain.Vehicle;
import com.gomove.vehicle.domain.VehicleRepository;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.sql.Timestamp;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.within;

@Transactional
class DriverLocationPostGisIntegrationTest extends BaseIntegrationTest {
    private static final double HOAN_KIEM_LAT = 21.0287;
    private static final double HOAN_KIEM_LON = 105.8524;
    private static final double OPERA_LAT = 21.0245;
    private static final double OPERA_LON = 105.8576;

    @Autowired JdbcTemplate jdbc;
    @Autowired UserRepository users;
    @Autowired DriverRepository drivers;
    @Autowired VehicleRepository vehicles;
    @Autowired DriverLocationRepository locations;
    @Autowired DriverLocationService service;

    @Test
    void v8CreatesLocationTableUniqueConstraintAndGistIndex() {
        assertThat(jdbc.queryForObject("SELECT to_regclass('public.driver_locations') IS NOT NULL", Boolean.class))
                .isTrue();
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM pg_constraint
                WHERE conrelid = 'driver_locations'::regclass
                  AND conname = 'uq_driver_locations_driver_id'
                  AND contype = 'u'
                """, Integer.class)).isEqualTo(1);
        String indexDefinition = jdbc.queryForObject("""
                SELECT indexdef FROM pg_indexes
                WHERE schemaname = 'public'
                  AND tablename = 'driver_locations'
                  AND indexname = 'idx_driver_locations_current_location_gist'
                """, String.class);
        assertThat(indexDefinition).containsIgnoringCase("USING gist (current_location)");
        assertThat(jdbc.queryForObject("""
                SELECT version FROM flyway_schema_history
                WHERE success = TRUE
                ORDER BY installed_rank DESC
                LIMIT 1
                """, String.class)).isEqualTo("8");
    }

    @Test
    void upsertKeepsExactlyOneLatestLocationRow() {
        Driver driver = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE, false);
        Instant firstUpdate = Instant.parse("2026-10-07T10:00:00Z");
        Instant secondUpdate = firstUpdate.plusSeconds(5);

        locations.upsertLatest(driver.getId(), HOAN_KIEM_LAT, HOAN_KIEM_LON, 10.0, 90.0, firstUpdate);
        locations.upsertLatest(driver.getId(), OPERA_LAT, OPERA_LON, 5.0, 180.0, secondUpdate);

        DriverLocation latest = locations.findByDriverId(driver.getId()).orElseThrow();
        assertThat(locations.countByDriverId(driver.getId())).isEqualTo(1);
        assertThat(latest.getCurrentLocation().getSRID()).isEqualTo(4326);
        assertThat(latest.getCurrentLocation().getY()).isCloseTo(OPERA_LAT, within(0.000001));
        assertThat(latest.getCurrentLocation().getX()).isCloseTo(OPERA_LON, within(0.000001));
        assertThat(latest.getAccuracy()).isEqualTo(5.0);
        assertThat(latest.getBearing()).isEqualTo(180.0);
        assertThat(latest.getUpdatedAt()).isEqualTo(secondUpdate);
        assertThat(latest.getVersion()).isEqualTo(1L);
    }

    @Test
    void uniqueDriverConstraintRejectsDuplicateRows() {
        Driver driver = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE, false);
        Instant now = Instant.parse("2026-10-07T10:00:00Z");
        locations.upsertLatest(driver.getId(), HOAN_KIEM_LAT, HOAN_KIEM_LON, null, null, now);

        assertThatThrownBy(() -> jdbc.update("""
                INSERT INTO driver_locations(driver_id, current_location, updated_at)
                VALUES (?, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?)
                """, driver.getId(), OPERA_LON, OPERA_LAT, Timestamp.from(now.plusSeconds(1))))
                .isInstanceOf(DataIntegrityViolationException.class);
    }

    @Test
    void distanceRadiusAndNearestFirstOrderingAreCorrect() {
        Instant now = Instant.parse("2026-10-07T10:00:00Z");
        Driver atLake = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE, true);
        Driver atOpera = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE, true);
        Driver farAway = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE, true);
        locations.upsertLatest(atLake.getId(), HOAN_KIEM_LAT, HOAN_KIEM_LON, null, null, now);
        locations.upsertLatest(atOpera.getId(), OPERA_LAT, OPERA_LON, null, null, now);
        locations.upsertLatest(farAway.getId(), 21.0580, 105.8170, null, null, now);

        List<NearbyDriverResult> withinFiveKm = service.findNearbyDrivers(
                HOAN_KIEM_LAT, HOAN_KIEM_LON, 5_000, now.minusSeconds(30), null
        );
        assertThat(withinFiveKm).extracting(NearbyDriverResult::driverPublicId)
                .containsExactly(atLake.getPublicId(), atOpera.getPublicId(), farAway.getPublicId());
        NearbyDriverResult operaResult = withinFiveKm.stream()
                .filter(result -> result.driverPublicId().equals(atOpera.getPublicId()))
                .findFirst()
                .orElseThrow();
        assertThat(operaResult.distanceMeters()).isBetween(700.0, 800.0);

        List<NearbyDriverResult> withinOneKm = service.findNearbyDrivers(
                HOAN_KIEM_LAT, HOAN_KIEM_LON, 1_000, now.minusSeconds(30), null
        );
        assertThat(withinOneKm).extracting(NearbyDriverResult::driverPublicId)
                .containsExactly(atLake.getPublicId(), atOpera.getPublicId())
                .doesNotContain(farAway.getPublicId());
    }

    @Test
    void nearbyQueryFiltersDriverStateAndRequiresActiveVehicle() {
        Instant now = Instant.parse("2026-10-07T10:00:00Z");
        Driver eligible = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE, true);
        Driver offline = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.OFFLINE, true);
        Driver busy = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.BUSY, true);
        Driver pending = driver(DriverApprovalStatus.PENDING, DriverOperatingStatus.OFFLINE, true);
        Driver withoutActiveVehicle = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE, false);
        for (Driver driver : List.of(eligible, offline, busy, pending, withoutActiveVehicle)) {
            locations.upsertLatest(driver.getId(), HOAN_KIEM_LAT, HOAN_KIEM_LON, null, null, now);
        }

        List<NearbyDriverResult> results = service.findNearbyDrivers(
                HOAN_KIEM_LAT, HOAN_KIEM_LON, 1_000, now.minusSeconds(30), 20
        );

        assertThat(results).extracting(NearbyDriverResult::driverPublicId)
                .containsExactly(eligible.getPublicId())
                .doesNotContain(
                        offline.getPublicId(),
                        busy.getPublicId(),
                        pending.getPublicId(),
                        withoutActiveVehicle.getPublicId()
                );
    }

    @Test
    void nearbyQueryExcludesStaleLocations() {
        Instant now = Instant.parse("2026-10-07T10:00:00Z");
        Driver fresh = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE, true);
        Driver stale = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE, true);
        locations.upsertLatest(fresh.getId(), HOAN_KIEM_LAT, HOAN_KIEM_LON, null, null, now.minusSeconds(5));
        locations.upsertLatest(stale.getId(), HOAN_KIEM_LAT, HOAN_KIEM_LON, null, null, now.minusSeconds(60));

        List<NearbyDriverResult> results = service.findNearbyDrivers(
                HOAN_KIEM_LAT, HOAN_KIEM_LON, 1_000, now.minusSeconds(30), null
        );

        assertThat(results).extracting(NearbyDriverResult::driverPublicId)
                .containsExactly(fresh.getPublicId())
                .doesNotContain(stale.getPublicId());
    }

    private Driver driver(
            DriverApprovalStatus approvalStatus,
            DriverOperatingStatus operatingStatus,
            boolean activeVehicle
    ) {
        User user = users.saveAndFlush(new User(
                "09" + Long.toUnsignedString(System.nanoTime(), 36),
                "spatial-" + code() + "@example.test",
                "bcrypt",
                "Spatial Test"
        ));
        user.setRole(UserRole.DRIVER);
        users.saveAndFlush(user);

        Driver driver = new Driver(user, "SPATIAL-" + code());
        driver.setApprovalStatus(approvalStatus);
        driver.setOperatingStatus(operatingStatus);
        driver = drivers.saveAndFlush(driver);

        if (activeVehicle) {
            Vehicle vehicle = new Vehicle(
                    driver,
                    "HN-" + code(),
                    VehicleType.MOTORBIKE,
                    "Honda",
                    "Wave",
                    "Blue"
            );
            vehicle.setActive(true);
            vehicles.saveAndFlush(vehicle);
        }
        return driver;
    }

    private String code() {
        return UUID.randomUUID().toString().substring(0, 8);
    }
}
