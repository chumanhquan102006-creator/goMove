package com.gomove.driver;

import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.common.exception.DomainException;
import com.gomove.driver.domain.Driver;
import com.gomove.driver.domain.DriverApprovalStatus;
import com.gomove.driver.domain.DriverOperatingStatus;
import com.gomove.driver.domain.DriverRepository;
import com.gomove.driver.service.DriverService;
import com.gomove.vehicle.api.CreateVehicleRequest;
import com.gomove.vehicle.domain.Vehicle;
import com.gomove.vehicle.domain.VehicleRepository;
import com.gomove.vehicle.domain.VehicleType;
import com.gomove.vehicle.service.VehicleService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class DriverVehicleIntegrationTest extends BaseIntegrationTest {
    @Autowired
    JdbcTemplate jdbc;
    @Autowired
    UserRepository users;
    @Autowired
    DriverRepository drivers;
    @Autowired
    VehicleRepository vehicles;
    @Autowired
    DriverService driverService;
    @Autowired
    VehicleService vehicleService;

    @Test
    void flywayMigrationsV5V6ShouldCreateTablesAndIndexes() {
        Integer driversTable = jdbc.queryForObject(
                "select count(*) from information_schema.tables where table_schema='public' and table_name='drivers'",
                Integer.class
        );
        Integer vehiclesTable = jdbc.queryForObject(
                "select count(*) from information_schema.tables where table_schema='public' and table_name='vehicles'",
                Integer.class
        );
        Integer driversIdx = jdbc.queryForObject(
                "select count(*) from pg_indexes where schemaname='public' and indexname='idx_drivers_license_number'",
                Integer.class
        );
        Integer vehiclesIdx = jdbc.queryForObject(
                "select count(*) from pg_indexes where schemaname='public' and indexname='idx_vehicles_driver_id'",
                Integer.class
        );

        assertThat(driversTable).isEqualTo(1);
        assertThat(vehiclesTable).isEqualTo(1);
        assertThat(driversIdx).isEqualTo(1);
        assertThat(vehiclesIdx).isEqualTo(1);
    }

    @Test
    void flywayV7ShouldCreateDriverVehicleIntegrityConstraints() {
        Integer activeVehicleIndex = jdbc.queryForObject(
                "select count(*) from pg_indexes where schemaname='public' and indexname='ux_vehicles_one_active_per_driver'",
                Integer.class
        );
        Integer constraints = jdbc.queryForObject(
                "select count(*) from pg_constraint where conrelid = 'drivers'::regclass and conname in " +
                        "('chk_drivers_operating_requires_approved', 'chk_drivers_rating_average_range', 'chk_drivers_total_trips_non_negative')",
                Integer.class
        );

        assertThat(activeVehicleIndex).isEqualTo(1);
        assertThat(constraints).isEqualTo(3);
    }

    @Test
    void databaseShouldRejectTwoActiveVehiclesForOneDriver() {
        Driver driver = createDriver("active-vehicles");

        insertVehicle(driver.getId(), "ACTIVE-ONE", true);

        assertThatThrownBy(() -> insertVehicle(driver.getId(), "ACTIVE-TWO", true))
                .isInstanceOf(DataIntegrityViolationException.class);
    }

    @Test
    void databaseShouldRejectOnlineOrBusyDriverUnlessApproved() {
        assertThatThrownBy(() -> insertDriverWithState("pending-online", "PENDING", "ONLINE", "5.00", 0))
                .isInstanceOf(DataIntegrityViolationException.class);
        assertThatThrownBy(() -> insertDriverWithState("suspended-busy", "SUSPENDED", "BUSY", "5.00", 0))
                .isInstanceOf(DataIntegrityViolationException.class);
    }

    @Test
    void databaseShouldRejectRatingOutsideAllowedRange() {
        assertThatThrownBy(() -> insertDriverWithState("rating-low", "APPROVED", "OFFLINE", "-0.01", 0))
                .isInstanceOf(DataIntegrityViolationException.class);
        assertThatThrownBy(() -> insertDriverWithState("rating-high", "APPROVED", "OFFLINE", "5.01", 0))
                .isInstanceOf(DataIntegrityViolationException.class);
    }

    @Test
    void databaseShouldRejectNegativeTotalTrips() {
        assertThatThrownBy(() -> insertDriverWithState("negative-trips", "APPROVED", "OFFLINE", "5.00", -1))
                .isInstanceOf(DataIntegrityViolationException.class);
    }

    @Test
    void dualStateMachineShouldEnforceApprovalAndActiveVehicle() {
        User user = users.save(new User("0901234999", "driver.state@example.test", "bcrypt", "Driver State"));
        Driver driver = driverService.registerDriver(user.getId(), "LIC-DUAL-001");

        assertThatThrownBy(() -> driverService.setOperatingStatus(driver.getPublicId(), DriverOperatingStatus.ONLINE))
                .isInstanceOf(DomainException.class);

        driverService.updateApprovalStatus(driver.getPublicId(), DriverApprovalStatus.APPROVED);
        assertThatThrownBy(() -> driverService.setOperatingStatus(driver.getPublicId(), DriverOperatingStatus.ONLINE))
                .isInstanceOf(DomainException.class);

        Vehicle vehicle = vehicleService.addVehicle(
                driver.getPublicId(),
                new CreateVehicleRequest("79A-999.99", VehicleType.MOTORBIKE, "Honda", "Wave", "Blue")
        );
        vehicleService.setActiveVehicle(driver.getPublicId(), vehicle.getPublicId());

        Driver online = driverService.setOperatingStatus(driver.getPublicId(), DriverOperatingStatus.ONLINE);
        assertThat(online.getOperatingStatus()).isEqualTo(DriverOperatingStatus.ONLINE);

        Driver forcedOffline = driverService.updateApprovalStatus(driver.getPublicId(), DriverApprovalStatus.SUSPENDED);
        assertThat(forcedOffline.getOperatingStatus()).isEqualTo(DriverOperatingStatus.OFFLINE);
    }

    @Test
    void activateVehicleShouldKeepOnlyOneActiveVehicle() {
        User user = users.save(new User("0901234888", "driver.vehicle@example.test", "bcrypt", "Driver Vehicle"));
        Driver driver = driverService.registerDriver(user.getId(), "LIC-DUAL-002");
        driverService.updateApprovalStatus(driver.getPublicId(), DriverApprovalStatus.APPROVED);

        Vehicle first = vehicleService.addVehicle(
                driver.getPublicId(),
                new CreateVehicleRequest("79A-123.11", VehicleType.MOTORBIKE, "Honda", "Blade", "Black")
        );
        Vehicle second = vehicleService.addVehicle(
                driver.getPublicId(),
                new CreateVehicleRequest("79A-123.22", VehicleType.CAR_4_SEAT, "Toyota", "Vios", "White")
        );

        vehicleService.setActiveVehicle(driver.getPublicId(), first.getPublicId());
        vehicleService.setActiveVehicle(driver.getPublicId(), second.getPublicId());

        Vehicle latestFirst = vehicles.findByPublicIdAndDriverId(first.getPublicId(), driver.getId()).orElseThrow();
        Vehicle latestSecond = vehicles.findByPublicIdAndDriverId(second.getPublicId(), driver.getId()).orElseThrow();

        assertThat(latestFirst.isActive()).isFalse();
        assertThat(latestSecond.isActive()).isTrue();
    }

    private Driver createDriver(String suffix) {
        User user = users.save(new User("09" + uniqueDigits(), suffix + "@example.test", "bcrypt", "Driver " + suffix));
        return driverService.registerDriver(user.getId(), "LIC-" + UUID.randomUUID());
    }

    private void insertVehicle(Long driverId, String licensePlatePrefix, boolean active) {
        jdbc.update(
                "insert into vehicles (driver_id, public_id, license_plate, vehicle_type, is_active, version, created_at, updated_at) " +
                        "values (?, ?, ?, 'MOTORBIKE', ?, 0, current_timestamp, current_timestamp)",
                driverId, UUID.randomUUID(), licensePlatePrefix + '-' + uniqueCode(), active
        );
    }

    private void insertDriverWithState(String suffix, String approvalStatus, String operatingStatus, String ratingAverage, int totalTrips) {
        User user = users.save(new User("08" + uniqueDigits(), suffix + "@example.test", "bcrypt", "Driver " + suffix));
        jdbc.update(
                "insert into drivers (user_id, public_id, license_number, approval_status, operating_status, rating_average, total_trips, version, created_at, updated_at) " +
                        "values (?, ?, ?, ?, ?, ?, ?, 0, current_timestamp, current_timestamp)",
                user.getId(), UUID.randomUUID(), "LIC-" + UUID.randomUUID(), approvalStatus, operatingStatus, new java.math.BigDecimal(ratingAverage), totalTrips
        );
    }

    private String uniqueDigits() {
        return String.valueOf(System.nanoTime()).replace('-', '7');
    }

    private String uniqueCode() {
        return UUID.randomUUID().toString().substring(0, 8);
    }
}
