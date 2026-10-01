package com.gomove.driver.domain;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;
import java.util.UUID;

public interface DriverRepository extends JpaRepository<Driver, Long> {
    Optional<Driver> findByPublicId(UUID publicId);

    Optional<Driver> findByUserId(Long userId);

    boolean existsByLicenseNumber(String licenseNumber);
}
