package com.gomove.vehicle.api;

import com.gomove.vehicle.domain.Vehicle;

import java.util.UUID;

public record VehicleResponse(
        UUID publicId,
        UUID driverPublicId,
        String licensePlate,
        String vehicleType,
        String brand,
        String model,
        String color,
        boolean active
) {
    public static VehicleResponse from(Vehicle vehicle) {
        return new VehicleResponse(
                vehicle.getPublicId(),
                vehicle.getDriver().getPublicId(),
                vehicle.getLicensePlate(),
                vehicle.getVehicleType().name(),
                vehicle.getBrand(),
                vehicle.getModel(),
                vehicle.getColor(),
                vehicle.isActive()
        );
    }
}
