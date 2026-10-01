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
import org.springframework.jdbc.core.JdbcTemplate;

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
}
