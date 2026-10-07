package com.gomove.driver.domain;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.EntityGraph;

import java.util.Optional;
import java.util.UUID;

public interface DriverRepository extends JpaRepository<Driver, Long> {
    @EntityGraph(attributePaths = "user")
    Optional<Driver> findByPublicId(UUID publicId);

    Optional<Driver> findByUserId(Long userId);

    @EntityGraph(attributePaths = "user")
    Optional<Driver> findByUserPublicId(UUID userPublicId);

    boolean existsByLicenseNumber(String licenseNumber);
}
