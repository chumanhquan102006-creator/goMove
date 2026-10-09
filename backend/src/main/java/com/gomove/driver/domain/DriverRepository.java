package com.gomove.driver.domain;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.EntityGraph;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface DriverRepository extends JpaRepository<Driver, Long> {
    @EntityGraph(attributePaths = "user")
    Optional<Driver> findByPublicId(UUID publicId);

    Optional<Driver> findByUserId(Long userId);

    @EntityGraph(attributePaths = "user")
    Optional<Driver> findByUserPublicId(UUID userPublicId);

    boolean existsByLicenseNumber(String licenseNumber);

    @Query(value = "SELECT EXISTS (SELECT 1 FROM bookings WHERE assigned_driver_id = :driverId AND driver_released_at IS NULL)",
            nativeQuery = true)
    boolean hasUnreleasedBooking(@Param("driverId") Long driverId);
}
