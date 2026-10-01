package com.gomove.vehicle.service;

import com.gomove.common.exception.DomainException;
import com.gomove.driver.domain.Driver;
import com.gomove.driver.domain.DriverRepository;
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
    private final DriverRepository drivers;

    public VehicleService(VehicleRepository vehicles, DriverRepository drivers) {
        this.vehicles = vehicles;
        this.drivers = drivers;
    }

    @Transactional
    public Vehicle addVehicle(UUID driverPublicId, CreateVehicleRequest request) {
        if (vehicles.existsByLicensePlate(request.licensePlate())) {
            throw new DomainException(HttpStatus.CONFLICT, "LICENSE_PLATE_EXISTS", "Vehicle license plate already exists");
        }

        Driver driver = findDriver(driverPublicId);
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
    public Vehicle setActiveVehicle(UUID driverPublicId, UUID vehiclePublicId) {
        Driver driver = findDriver(driverPublicId);
        List<Vehicle> byDriver = vehicles.findByDriverId(driver.getId());
        byDriver.forEach(v -> v.setActive(false));

        Vehicle target = vehicles.findByPublicIdAndDriverId(vehiclePublicId, driver.getId())
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND, "VEHICLE_NOT_FOUND", "Vehicle not found for driver"));
        target.setActive(true);
        return target;
    }

    @Transactional(readOnly = true)
    public List<Vehicle> findByDriverPublicId(UUID driverPublicId) {
        Driver driver = findDriver(driverPublicId);
        return vehicles.findByDriverId(driver.getId());
    }

    private Driver findDriver(UUID driverPublicId) {
        return drivers.findByPublicId(driverPublicId)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND, "DRIVER_NOT_FOUND", "Driver not found"));
    }
}
