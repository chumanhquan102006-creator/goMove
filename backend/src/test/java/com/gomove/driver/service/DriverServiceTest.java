package com.gomove.driver.service;

import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.common.exception.DomainException;
import com.gomove.driver.domain.Driver;
import com.gomove.driver.domain.DriverApprovalStatus;
import com.gomove.driver.domain.DriverOperatingStatus;
import com.gomove.driver.domain.DriverRepository;
import com.gomove.vehicle.domain.Vehicle;
import com.gomove.vehicle.domain.VehicleRepository;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class DriverServiceTest {
    @Mock
    DriverRepository drivers;
    @Mock
    UserRepository users;
    @Mock
    VehicleRepository vehicles;

    DriverService service;

    @BeforeEach
    void setUp() {
        service = new DriverService(drivers, users, vehicles);
    }

    @Test
    void registerDriverInitializesPendingAndOffline() {
        User user = new User("0900000002", "driver@example.test", "bcrypt", "Driver User");
        ReflectionTestUtils.setField(user, "id", 10L);
        when(drivers.existsByLicenseNumber("LIC-123")).thenReturn(false);
        when(drivers.findByUserId(10L)).thenReturn(Optional.empty());
        when(users.findById(10L)).thenReturn(Optional.of(user));
        when(drivers.save(any(Driver.class))).thenAnswer(invocation -> invocation.getArgument(0));

        Driver created = service.registerDriver(10L, "LIC-123");

        assertThat(created.getApprovalStatus()).isEqualTo(DriverApprovalStatus.PENDING);
        assertThat(created.getOperatingStatus()).isEqualTo(DriverOperatingStatus.OFFLINE);
    }

    @Test
    void updateApprovalStatusRejectedForcesOffline() {
        Driver driver = new Driver(new User("0900", null, "bcrypt", "N"), "LIC-001");
        driver.setApprovalStatus(DriverApprovalStatus.APPROVED);
        driver.setOperatingStatus(DriverOperatingStatus.ONLINE);
        UUID driverPublicId = UUID.randomUUID();
        ReflectionTestUtils.setField(driver, "publicId", driverPublicId);
        when(drivers.findByPublicId(driverPublicId)).thenReturn(Optional.of(driver));

        Driver updated = service.updateApprovalStatus(driverPublicId, DriverApprovalStatus.REJECTED);

        assertThat(updated.getApprovalStatus()).isEqualTo(DriverApprovalStatus.REJECTED);
        assertThat(updated.getOperatingStatus()).isEqualTo(DriverOperatingStatus.OFFLINE);
    }

    @Test
    void setOperatingStatusOnlineFailsWhenNotApproved() {
        Driver driver = new Driver(new User("0900", null, "bcrypt", "N"), "LIC-002");
        UUID driverPublicId = UUID.randomUUID();
        ReflectionTestUtils.setField(driver, "id", 99L);
        ReflectionTestUtils.setField(driver, "publicId", driverPublicId);
        driver.setApprovalStatus(DriverApprovalStatus.PENDING);
        when(drivers.findByPublicId(driverPublicId)).thenReturn(Optional.of(driver));

        assertThatThrownBy(() -> service.setOperatingStatus(driverPublicId, DriverOperatingStatus.ONLINE))
                .isInstanceOf(DomainException.class);
    }

    @Test
    void setOperatingStatusOnlineFailsWhenNoActiveVehicle() {
        Driver driver = new Driver(new User("0900", null, "bcrypt", "N"), "LIC-003");
        UUID driverPublicId = UUID.randomUUID();
        ReflectionTestUtils.setField(driver, "id", 100L);
        ReflectionTestUtils.setField(driver, "publicId", driverPublicId);
        driver.setApprovalStatus(DriverApprovalStatus.APPROVED);
        when(drivers.findByPublicId(driverPublicId)).thenReturn(Optional.of(driver));
        when(vehicles.findByDriverIdAndIsActiveTrue(100L)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.setOperatingStatus(driverPublicId, DriverOperatingStatus.ONLINE))
                .isInstanceOf(DomainException.class);
    }

    @Test
    void setOperatingStatusOnlineSucceedsWhenApprovedAndHasActiveVehicle() {
        Driver driver = new Driver(new User("0900", null, "bcrypt", "N"), "LIC-004");
        UUID driverPublicId = UUID.randomUUID();
        ReflectionTestUtils.setField(driver, "id", 101L);
        ReflectionTestUtils.setField(driver, "publicId", driverPublicId);
        driver.setApprovalStatus(DriverApprovalStatus.APPROVED);
        when(drivers.findByPublicId(driverPublicId)).thenReturn(Optional.of(driver));
        when(vehicles.findByDriverIdAndIsActiveTrue(101L)).thenReturn(Optional.of(
                new Vehicle(driver, "79A-111.11", VehicleType.MOTORBIKE, "Honda", "Wave", "Black")
        ));

        Driver updated = service.setOperatingStatus(driverPublicId, DriverOperatingStatus.ONLINE);

        assertThat(updated.getOperatingStatus()).isEqualTo(DriverOperatingStatus.ONLINE);
    }
}
