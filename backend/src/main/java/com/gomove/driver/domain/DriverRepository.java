package com.gomove.driver.domain;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.EntityGraph;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.Lock;

import java.util.Optional;
import java.util.UUID;

public interface DriverRepository extends JpaRepository<Driver, Long> {
    @EntityGraph(attributePaths = "user")
    Optional<Driver> findByPublicId(UUID publicId);

    Optional<Driver> findByUserId(Long userId);

    @EntityGraph(attributePaths = "user")
    Optional<Driver> findByUserPublicId(UUID userPublicId);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select d from Driver d where d.publicId = :publicId")
    Optional<Driver> lockByPublicId(@Param("publicId") UUID publicId);

    boolean existsByLicenseNumber(String licenseNumber);

    @Query(value = "SELECT EXISTS (SELECT 1 FROM bookings WHERE assigned_driver_id = :driverId AND driver_released_at IS NULL)",
            nativeQuery = true)
    boolean hasUnreleasedBooking(@Param("driverId") Long driverId);
}
