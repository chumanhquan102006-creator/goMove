package com.gomove.vehicle.domain;

import com.gomove.common.persistence.BaseEntity;
import com.gomove.driver.domain.Driver;
import jakarta.persistence.*;

@Entity
@Table(name = "vehicles")
public class Vehicle extends BaseEntity {
    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "driver_id", nullable = false)
    private Driver driver;

    @Column(name = "license_plate", nullable = false, unique = true, length = 20)
    private String licensePlate;

    @Enumerated(EnumType.STRING)
    @Column(name = "vehicle_type", nullable = false, length = 20)
    private VehicleType vehicleType;

    @Column(length = 50)
    private String brand;

    @Column(length = 50)
    private String model;

    @Column(length = 30)
    private String color;

    @Column(name = "is_active", nullable = false)
    private boolean isActive;

    protected Vehicle() {
    }

    public Vehicle(Driver driver, String licensePlate, VehicleType vehicleType, String brand, String model, String color) {
        this.driver = driver;
        this.licensePlate = licensePlate;
        this.vehicleType = vehicleType;
        this.brand = brand;
        this.model = model;
        this.color = color;
        this.isActive = false;
    }

    public Driver getDriver() {
        return driver;
    }

    public String getLicensePlate() {
        return licensePlate;
    }

    public VehicleType getVehicleType() {
        return vehicleType;
    }

    public String getBrand() {
        return brand;
    }

    public String getModel() {
        return model;
    }

    public String getColor() {
        return color;
    }

    public boolean isActive() {
        return isActive;
    }

    public void setActive(boolean active) {
        isActive = active;
    }
}
