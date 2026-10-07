package com.gomove.driver;

import com.gomove.auth.domain.*;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.driver.domain.*;
import com.gomove.vehicle.domain.*;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;

import java.math.BigDecimal;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;

class DriverVehicleIntegrationTest extends BaseIntegrationTest {
    @Autowired JdbcTemplate jdbc;
    @Autowired UserRepository users;
    @Autowired DriverRepository drivers;
    @Autowired VehicleRepository vehicles;

    @Test void flywayV5ThroughV7CreateRequiredTablesAndIntegrityRules() {
        assertThat(jdbc.queryForObject("select count(*) from information_schema.tables where table_name in ('drivers', 'vehicles')", Integer.class)).isEqualTo(2);
        assertThat(jdbc.queryForObject("select count(*) from pg_indexes where indexname='ux_vehicles_one_active_per_driver'", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("select count(*) from pg_constraint where conrelid='drivers'::regclass and conname in ('chk_drivers_operating_requires_approved','chk_drivers_rating_average_range','chk_drivers_total_trips_non_negative')", Integer.class)).isEqualTo(3);
    }

    @Test void databaseRejectsTwoActiveVehiclesForOneDriver() {
        Driver driver = driver("active");
        insertVehicle(driver.getId(), "ACTIVE-ONE", true);
        assertThatThrownBy(() -> insertVehicle(driver.getId(), "ACTIVE-TWO", true)).isInstanceOf(DataIntegrityViolationException.class);
    }

    @Test void databaseRejectsInvalidOperatingApprovalCombinations() {
        assertThatThrownBy(() -> insertDriver("pending-online", "PENDING", "ONLINE", "5.00", 0)).isInstanceOf(DataIntegrityViolationException.class);
        assertThatThrownBy(() -> insertDriver("suspended-busy", "SUSPENDED", "BUSY", "5.00", 0)).isInstanceOf(DataIntegrityViolationException.class);
    }

    @Test void databaseRejectsInvalidRatingAndTripTotals() {
        assertThatThrownBy(() -> insertDriver("rating-low", "APPROVED", "OFFLINE", "-0.01", 0)).isInstanceOf(DataIntegrityViolationException.class);
        assertThatThrownBy(() -> insertDriver("rating-high", "APPROVED", "OFFLINE", "5.01", 0)).isInstanceOf(DataIntegrityViolationException.class);
        assertThatThrownBy(() -> insertDriver("trips-negative", "APPROVED", "OFFLINE", "5.00", -1)).isInstanceOf(DataIntegrityViolationException.class);
    }

    @Test void approvedDriverCanHaveAnActiveVehicle() {
        Driver driver = driver("valid");
        Vehicle vehicle = new Vehicle(driver, "VALID-" + code(), VehicleType.MOTORBIKE, "Honda", "Wave", "Blue");
        vehicle.setActive(true);
        vehicles.saveAndFlush(vehicle);
        assertThat(vehicles.findByDriverIdAndIsActiveTrue(driver.getId())).isPresent();
    }

    private Driver driver(String suffix) {
        User user = users.saveAndFlush(new User("09" + digits(), suffix + "@example.test", "bcrypt", "Driver " + suffix));
        user.setRole(UserRole.DRIVER);
        users.saveAndFlush(user);
        Driver driver = new Driver(user, "LIC-" + code());
        driver.setApprovalStatus(DriverApprovalStatus.APPROVED);
        return drivers.saveAndFlush(driver);
    }

    private void insertVehicle(Long driverId, String prefix, boolean active) {
        jdbc.update("insert into vehicles (driver_id, public_id, license_plate, vehicle_type, is_active, version, created_at, updated_at) values (?, ?, ?, 'MOTORBIKE', ?, 0, current_timestamp, current_timestamp)", driverId, UUID.randomUUID(), prefix + '-' + code(), active);
    }

    private void insertDriver(String suffix, String approval, String operating, String rating, int trips) {
        User user = users.saveAndFlush(new User("08" + digits(), suffix + "@example.test", "bcrypt", "Driver " + suffix));
        jdbc.update("insert into drivers (user_id, public_id, license_number, approval_status, operating_status, rating_average, total_trips, version, created_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, 0, current_timestamp, current_timestamp)", user.getId(), UUID.randomUUID(), "LIC-" + code(), approval, operating, new BigDecimal(rating), trips);
    }

    private String digits() { return String.valueOf(System.nanoTime()).replace('-', '7'); }
    private String code() { return UUID.randomUUID().toString().substring(0, 8); }
}
