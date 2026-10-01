package com.gomove.driver.service;

import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
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
    public Driver registerDriver(Long userId, String licenseNumber) {
        if (drivers.existsByLicenseNumber(licenseNumber)) {
            throw new DomainException(HttpStatus.CONFLICT, "LICENSE_NUMBER_EXISTS", "Driver license number already exists");
        }
        if (drivers.findByUserId(userId).isPresent()) {
            throw new DomainException(HttpStatus.CONFLICT, "USER_ALREADY_DRIVER", "User is already registered as a driver");
        }
        User user = users.findById(userId)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND, "USER_NOT_FOUND", "User not found"));

        Driver driver = new Driver(user, licenseNumber);
        driver.setApprovalStatus(DriverApprovalStatus.PENDING);
        driver.setOperatingStatus(DriverOperatingStatus.OFFLINE);
        return drivers.save(driver);
    }

    @Transactional
    public Driver updateApprovalStatus(UUID driverPublicId, DriverApprovalStatus newStatus) {
        Driver driver = findDriver(driverPublicId);
        driver.setApprovalStatus(newStatus);
        if (newStatus == DriverApprovalStatus.SUSPENDED || newStatus == DriverApprovalStatus.REJECTED) {
            driver.setOperatingStatus(DriverOperatingStatus.OFFLINE);
        }
        return driver;
    }

    @Transactional
    public Driver setOperatingStatus(UUID driverPublicId, DriverOperatingStatus targetStatus) {
        Driver driver = findDriver(driverPublicId);
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

    private Driver findDriver(UUID driverPublicId) {
        return drivers.findByPublicId(driverPublicId)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND, "DRIVER_NOT_FOUND", "Driver not found"));
    }
}
