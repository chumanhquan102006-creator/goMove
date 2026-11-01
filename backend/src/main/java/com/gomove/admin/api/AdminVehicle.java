package com.gomove.admin.api;

import java.util.UUID;

public record AdminVehicle(UUID publicId, String licensePlate, String vehicleType,
                           String brand, String model, String color, boolean active) {}
