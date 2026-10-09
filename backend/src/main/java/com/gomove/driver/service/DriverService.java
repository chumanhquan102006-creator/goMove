package com.gomove.driver.service;

import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.auth.domain.UserRole;
import com.gomove.common.exception.DomainException;
import com.gomove.driver.domain.Driver;
import com.gomove.driver.domain.DriverApprovalStatus;
import com.gomove.driver.domain.DriverOperatingStatus;
import com.gomove.driver.domain.DriverRepository;
import com.gomove.vehicle.domain.VehicleRepository;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

@Service
public class DriverService {
    private final DriverRepository drivers;
    private final UserRepository users;
    private final VehicleRepository vehicles;

    public DriverService(DriverRepository drivers, UserRepository users, VehicleRepository vehicles) {
        this.drivers = drivers;
        this.users = users;
        this.vehicles = vehicles;
    }

    @Transactional
    public Driver onboardCurrentCustomer(UUID userPublicId, UserRole authenticatedRole, String licenseNumber) {
        requireRole(authenticatedRole, UserRole.CUSTOMER);
        User user = users.findByPublicId(userPublicId)
                .orElseThrow(() -> new DomainException(HttpStatus.UNAUTHORIZED, "UNAUTHORIZED", "Authenticated user was not found"));
        if (user.getRole() != UserRole.CUSTOMER) {
            throw new DomainException(HttpStatus.FORBIDDEN, "DRIVER_ONBOARDING_NOT_ALLOWED", "Only customer accounts can request driver onboarding");
        }
        if (drivers.findByUserId(user.getId()).isPresent()) {
            throw new DomainException(HttpStatus.CONFLICT, "USER_ALREADY_DRIVER", "User is already registered as a driver");
        }
        if (drivers.existsByLicenseNumber(licenseNumber)) {
            throw new DomainException(HttpStatus.CONFLICT, "LICENSE_NUMBER_EXISTS", "Driver license number already exists");
        }

        Driver driver = new Driver(user, licenseNumber);
        driver.setApprovalStatus(DriverApprovalStatus.PENDING);
        driver.setOperatingStatus(DriverOperatingStatus.OFFLINE);
        user.setRole(UserRole.DRIVER);
        return drivers.save(driver);
    }

    @Transactional
    public Driver updateApprovalStatusAsAdmin(UserRole authenticatedRole, UUID driverPublicId, DriverApprovalStatus newStatus) {
        requireRole(authenticatedRole, UserRole.ADMIN);
        Driver driver = findDriver(driverPublicId);
        if ((newStatus == DriverApprovalStatus.SUSPENDED || newStatus == DriverApprovalStatus.REJECTED)
                && drivers.hasUnreleasedBooking(driver.getId())) {
            throw new DomainException(HttpStatus.CONFLICT, "DRIVER_HAS_UNRELEASED_BOOKING",
                    "Driver approval cannot change while an assigned Booking is unreleased");
        }
        driver.setApprovalStatus(newStatus);
        if (newStatus == DriverApprovalStatus.SUSPENDED || newStatus == DriverApprovalStatus.REJECTED) {
            driver.setOperatingStatus(DriverOperatingStatus.OFFLINE);
        }
        return driver;
    }

    @Transactional
    public Driver setOwnOperatingStatus(UUID userPublicId, UserRole authenticatedRole, DriverOperatingStatus targetStatus) {
        Driver driver = requireDriverProfile(userPublicId, authenticatedRole);
        if (targetStatus == DriverOperatingStatus.BUSY) {
            throw new DomainException(HttpStatus.FORBIDDEN, "BUSY_STATUS_SYSTEM_MANAGED", "BUSY status is managed by the trip lifecycle");
        }
        if (driver.getOperatingStatus() == DriverOperatingStatus.BUSY
                && drivers.hasUnreleasedBooking(driver.getId())) {
            throw new DomainException(HttpStatus.CONFLICT, "DRIVER_HAS_UNRELEASED_BOOKING",
                    "Driver remains busy until the assigned Booking is released");
        }
        if (targetStatus == DriverOperatingStatus.ONLINE) {
            if (driver.getApprovalStatus() != DriverApprovalStatus.APPROVED) {
                throw new DomainException("DRIVER_NOT_APPROVED", "Driver is not approved to go online");
            }
            if (vehicles.findByDriverIdAndIsActiveTrue(driver.getId()).isEmpty()) {
                throw new DomainException("ACTIVE_VEHICLE_REQUIRED", "Driver must have at least one active vehicle to go online");
            }
        }
        driver.setOperatingStatus(targetStatus);
        return driver;
    }

    @Transactional(readOnly = true)
    public Driver findByPublicId(UUID driverPublicId) {
        return findDriver(driverPublicId);
    }

    @Transactional(readOnly = true)
    public Driver requireDriverProfile(UUID userPublicId, UserRole authenticatedRole) {
        requireRole(authenticatedRole, UserRole.DRIVER);
        return drivers.findByUserPublicId(userPublicId)
                .orElseThrow(() -> new DomainException(HttpStatus.FORBIDDEN, "DRIVER_PROFILE_REQUIRED", "Driver profile is required"));
    }

    private void requireRole(UserRole actualRole, UserRole expectedRole) {
        if (actualRole != expectedRole) {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "You are not authorized to perform this action");
        }
    }

    private Driver findDriver(UUID driverPublicId) {
        return drivers.findByPublicId(driverPublicId)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND, "DRIVER_NOT_FOUND", "Driver not found"));
    }
}
