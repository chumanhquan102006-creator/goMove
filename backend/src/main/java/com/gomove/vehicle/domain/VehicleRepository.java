package com.gomove.vehicle.domain;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.EntityGraph;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface VehicleRepository extends JpaRepository<Vehicle, Long> {
    @EntityGraph(attributePaths = "driver")
    List<Vehicle> findByDriverId(Long driverId);

    Optional<Vehicle> findByDriverIdAndIsActiveTrue(Long driverId);

    boolean existsByLicensePlate(String licensePlate);

    @EntityGraph(attributePaths = "driver")
    Optional<Vehicle> findByPublicIdAndDriverId(UUID publicId, Long driverId);

    @Modifying(flushAutomatically = true, clearAutomatically = true)
    @Query("update Vehicle v set v.isActive = false where v.driver.id = :driverId and v.isActive = true")
    int deactivateActiveVehiclesByDriverId(@Param("driverId") Long driverId);
}
