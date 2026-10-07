package com.gomove.vehicle.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.common.exception.DomainException;
import com.gomove.driver.domain.Driver;
import com.gomove.driver.service.DriverService;
import com.gomove.vehicle.api.CreateVehicleRequest;
import com.gomove.vehicle.domain.Vehicle;
import com.gomove.vehicle.domain.VehicleRepository;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

@Service
public class VehicleService {
    private final VehicleRepository vehicles;
    private final DriverService driverService;

    public VehicleService(VehicleRepository vehicles, DriverService driverService) {
        this.vehicles = vehicles;
        this.driverService = driverService;
    }

    @Transactional
    public Vehicle addVehicleForCurrentDriver(UUID userPublicId, UserRole authenticatedRole, CreateVehicleRequest request) {
        if (vehicles.existsByLicensePlate(request.licensePlate())) {
            throw new DomainException(HttpStatus.CONFLICT, "LICENSE_PLATE_EXISTS", "Vehicle license plate already exists");
        }

        Driver driver = driverService.requireDriverProfile(userPublicId, authenticatedRole);
        Vehicle vehicle = new Vehicle(
                driver,
                request.licensePlate(),
                request.vehicleType(),
                request.brand(),
                request.model(),
                request.color()
        );
        return vehicles.save(vehicle);
    }

    @Transactional
    public Vehicle setActiveVehicleForCurrentDriver(UUID userPublicId, UserRole authenticatedRole, UUID vehiclePublicId) {
        Driver driver = driverService.requireDriverProfile(userPublicId, authenticatedRole);
        vehicles.findByPublicIdAndDriverId(vehiclePublicId, driver.getId())
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND, "VEHICLE_NOT_FOUND", "Vehicle not found for driver"));
        vehicles.deactivateActiveVehiclesByDriverId(driver.getId());
        Vehicle target = vehicles.findByPublicIdAndDriverId(vehiclePublicId, driver.getId())
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND, "VEHICLE_NOT_FOUND", "Vehicle not found for driver"));
        target.setActive(true);
        return target;
    }

    @Transactional(readOnly = true)
    public List<Vehicle> findVehiclesForCurrentDriver(UUID userPublicId, UserRole authenticatedRole) {
        Driver driver = driverService.requireDriverProfile(userPublicId, authenticatedRole);
        return vehicles.findByDriverId(driver.getId());
    }

}
