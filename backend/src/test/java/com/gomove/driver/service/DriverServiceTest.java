package com.gomove.driver.service;

import com.gomove.auth.domain.*;
import com.gomove.common.exception.DomainException;
import com.gomove.driver.domain.*;
import com.gomove.vehicle.domain.VehicleRepository;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.*;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class DriverServiceTest {
    @Mock DriverRepository drivers;
    @Mock UserRepository users;
    @Mock VehicleRepository vehicles;
    DriverService service;

    @BeforeEach void setUp() { service = new DriverService(drivers, users, vehicles); }

    @Test void customerCanOnboardAndBecomesDriver() {
        User user = user(10L, UserRole.CUSTOMER);
        when(users.findByPublicId(user.getPublicId())).thenReturn(Optional.of(user));
        when(drivers.findByUserId(10L)).thenReturn(Optional.empty());
        when(drivers.existsByLicenseNumber("LIC-123")).thenReturn(false);
        when(drivers.save(any(Driver.class))).thenAnswer(invocation -> invocation.getArgument(0));

        Driver created = service.onboardCurrentCustomer(user.getPublicId(), UserRole.CUSTOMER, "LIC-123");

        assertThat(created.getApprovalStatus()).isEqualTo(DriverApprovalStatus.PENDING);
        assertThat(created.getOperatingStatus()).isEqualTo(DriverOperatingStatus.OFFLINE);
        assertThat(user.getRole()).isEqualTo(UserRole.DRIVER);
    }

    @Test void nonCustomerCannotOnboard() {
        assertThatThrownBy(() -> service.onboardCurrentCustomer(UUID.randomUUID(), UserRole.DRIVER, "LIC-123"))
                .isInstanceOf(DomainException.class);
    }

    @Test void onlyAdminCanUpdateApproval() {
        assertThatThrownBy(() -> service.updateApprovalStatusAsAdmin(UserRole.CUSTOMER, UUID.randomUUID(), DriverApprovalStatus.APPROVED))
                .isInstanceOf(DomainException.class);
    }

    @Test void rejectedApprovalForcesOffline() {
        User user = user(11L, UserRole.DRIVER);
        Driver driver = new Driver(user, "LIC-001");
        driver.setApprovalStatus(DriverApprovalStatus.APPROVED);
        driver.setOperatingStatus(DriverOperatingStatus.ONLINE);
        ReflectionTestUtils.setField(driver, "publicId", UUID.randomUUID());
        when(drivers.findByPublicId(driver.getPublicId())).thenReturn(Optional.of(driver));

        Driver updated = service.updateApprovalStatusAsAdmin(UserRole.ADMIN, driver.getPublicId(), DriverApprovalStatus.REJECTED);

        assertThat(updated.getOperatingStatus()).isEqualTo(DriverOperatingStatus.OFFLINE);
    }

    @Test void driverCannotSetBusyManually() {
        assertThatThrownBy(() -> service.setOwnOperatingStatus(UUID.randomUUID(), UserRole.DRIVER, DriverOperatingStatus.BUSY))
                .isInstanceOf(DomainException.class);
    }

    private User user(Long id, UserRole role) {
        User user = new User("0900" + id, null, "bcrypt", "Driver");
        ReflectionTestUtils.setField(user, "id", id);
        ReflectionTestUtils.setField(user, "publicId", UUID.randomUUID());
        user.setRole(role);
        return user;
    }
}
