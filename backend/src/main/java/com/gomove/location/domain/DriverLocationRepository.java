package com.gomove.location.domain;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.List;
import java.util.Optional;

public interface DriverLocationRepository extends JpaRepository<DriverLocation, Long> {
    Optional<DriverLocation> findByDriverId(Long driverId);

    long countByDriverId(Long driverId);

    @Modifying(flushAutomatically = true, clearAutomatically = true)
    @Query(value = """
            INSERT INTO driver_locations (
                driver_id, current_location, accuracy, bearing, updated_at, version
            ) VALUES (
                :driverId,
                ST_SetSRID(ST_MakePoint(:longitude, :latitude), 4326)::geography,
                :accuracy,
                :bearing,
                :updatedAt,
                0
            )
            ON CONFLICT (driver_id) DO UPDATE SET
                current_location = EXCLUDED.current_location,
                accuracy = EXCLUDED.accuracy,
                bearing = EXCLUDED.bearing,
                updated_at = EXCLUDED.updated_at,
                version = driver_locations.version + 1
            """, nativeQuery = true)
    int upsertLatest(
            @Param("driverId") Long driverId,
            @Param("latitude") double latitude,
            @Param("longitude") double longitude,
            @Param("accuracy") Double accuracy,
            @Param("bearing") Double bearing,
            @Param("updatedAt") Instant updatedAt
    );

    @Query(value = """
            SELECT
                d.public_id AS "driverPublicId",
                v.public_id AS "vehiclePublicId",
                ST_Y(dl.current_location::geometry) AS latitude,
                ST_X(dl.current_location::geometry) AS longitude,
                ST_Distance(
                    dl.current_location,
                    ST_SetSRID(ST_MakePoint(:longitude, :latitude), 4326)::geography
                ) AS "distanceMeters",
                dl.updated_at AS "locationUpdatedAt"
            FROM driver_locations dl
            JOIN drivers d ON d.id = dl.driver_id
            JOIN vehicles v ON v.driver_id = d.id AND v.is_active = TRUE
            WHERE d.approval_status = 'APPROVED'
              AND d.operating_status = 'ONLINE'
              AND dl.updated_at >= :freshnessCutoff
              AND ST_DWithin(
                    dl.current_location,
                    ST_SetSRID(ST_MakePoint(:longitude, :latitude), 4326)::geography,
                    :radiusMeters
              )
            ORDER BY ST_Distance(
                dl.current_location,
                ST_SetSRID(ST_MakePoint(:longitude, :latitude), 4326)::geography
            ) ASC
            LIMIT :resultLimit
            """, nativeQuery = true)
    List<NearbyDriverProjection> findNearbyEligibleDrivers(
            @Param("latitude") double latitude,
            @Param("longitude") double longitude,
            @Param("radiusMeters") double radiusMeters,
            @Param("freshnessCutoff") Instant freshnessCutoff,
            @Param("resultLimit") int resultLimit
    );
}
