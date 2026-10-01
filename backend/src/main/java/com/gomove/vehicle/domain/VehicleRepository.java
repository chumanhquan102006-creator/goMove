package com.gomove.vehicle.domain;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface VehicleRepository extends JpaRepository<Vehicle, Long> {
    List<Vehicle> findByDriverId(Long driverId);

    Optional<Vehicle> findByDriverIdAndIsActiveTrue(Long driverId);

    boolean existsByLicensePlate(String licensePlate);

    Optional<Vehicle> findByPublicIdAndDriverId(UUID publicId, Long driverId);
}
