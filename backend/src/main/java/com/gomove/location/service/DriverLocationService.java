package com.gomove.location.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.common.exception.DomainException;
import com.gomove.driver.domain.Driver;
import com.gomove.driver.domain.DriverApprovalStatus;
import com.gomove.driver.domain.DriverOperatingStatus;
import com.gomove.driver.service.DriverService;
import com.gomove.location.domain.DriverLocation;
import com.gomove.location.domain.DriverLocationRepository;
import com.gomove.location.infrastructure.LocationProperties;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

@Service
public class DriverLocationService {
    private static final int DEFAULT_RESULT_LIMIT = 50;

    private final DriverLocationRepository locations;
    private final DriverService drivers;
    private final LocationProperties properties;

    public DriverLocationService(
            DriverLocationRepository locations,
            DriverService drivers,
            LocationProperties properties
    ) {
        this.locations = locations;
        this.drivers = drivers;
        this.properties = properties;
    }

    @Transactional
    public DriverLocation updateOwnLocation(
            UUID userPublicId,
            UserRole authenticatedRole,
            double latitude,
            double longitude,
            Double accuracy,
            Double bearing
    ) {
        Driver driver = drivers.requireDriverProfile(userPublicId, authenticatedRole);
        requireLocationUpdateAllowed(driver);

        Instant updatedAt = Instant.now();
        locations.upsertLatest(driver.getId(), latitude, longitude, accuracy, bearing, updatedAt);
        return locations.findByDriverId(driver.getId())
                .orElseThrow(() -> new IllegalStateException("Driver location upsert did not produce a row"));
    }

    @Transactional(readOnly = true)
    public List<NearbyDriverResult> findNearbyDrivers(
            double pickupLatitude,
            double pickupLongitude,
            double radiusMeters,
            Instant freshnessCutoff,
            Integer resultLimit
    ) {
        validateSearchInput(pickupLatitude, pickupLongitude, radiusMeters, freshnessCutoff, resultLimit);
        int effectiveLimit = resultLimit == null ? DEFAULT_RESULT_LIMIT : resultLimit;
        return locations.findNearbyEligibleDrivers(
                        pickupLatitude,
                        pickupLongitude,
                        radiusMeters,
                        freshnessCutoff,
                        effectiveLimit
                ).stream()
                .map(result -> new NearbyDriverResult(
                        result.getDriverPublicId(),
                        result.getVehiclePublicId(),
                        result.getLatitude(),
                        result.getLongitude(),
                        result.getDistanceMeters(),
                        result.getLocationUpdatedAt()
                ))
                .toList();
    }

    @Transactional(readOnly = true)
    public List<NearbyDriverResult> findNearbyDriversForDispatch(
            double pickupLatitude,
            double pickupLongitude,
            double radiusMeters,
            Integer resultLimit
    ) {
        Instant cutoff = Instant.now().minusSeconds(properties.getDispatchFreshnessSeconds());
        return findNearbyDrivers(pickupLatitude, pickupLongitude, radiusMeters, cutoff, resultLimit);
    }

    private void requireLocationUpdateAllowed(Driver driver) {
        if (driver.getApprovalStatus() != DriverApprovalStatus.APPROVED) {
            throw new DomainException(
                    HttpStatus.CONFLICT,
                    "DRIVER_LOCATION_APPROVAL_REQUIRED",
                    "Only approved drivers can update location"
            );
        }
        if (driver.getOperatingStatus() != DriverOperatingStatus.ONLINE
                && driver.getOperatingStatus() != DriverOperatingStatus.BUSY) {
            throw new DomainException(
                    HttpStatus.CONFLICT,
                    "DRIVER_LOCATION_ACTIVE_STATUS_REQUIRED",
                    "Driver must be ONLINE or BUSY to update location"
            );
        }
    }

    private void validateSearchInput(
            double latitude,
            double longitude,
            double radiusMeters,
            Instant freshnessCutoff,
            Integer resultLimit
    ) {
        if (!Double.isFinite(latitude) || latitude < -90 || latitude > 90
                || !Double.isFinite(longitude) || longitude < -180 || longitude > 180) {
            throw new IllegalArgumentException("Pickup coordinates are outside valid bounds");
        }
        if (!Double.isFinite(radiusMeters) || radiusMeters < 0) {
            throw new IllegalArgumentException("Radius must be a non-negative finite value");
        }
        if (freshnessCutoff == null) {
            throw new IllegalArgumentException("Freshness cutoff is required");
        }
        if (resultLimit != null && resultLimit <= 0) {
            throw new IllegalArgumentException("Result limit must be positive");
        }
    }
}
