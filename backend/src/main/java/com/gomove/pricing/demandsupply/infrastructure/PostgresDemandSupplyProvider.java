package com.gomove.pricing.demandsupply.infrastructure;

import com.gomove.pricing.demandsupply.DemandSupplyMetrics;
import com.gomove.pricing.demandsupply.DemandSupplyPricingProperties;
import com.gomove.pricing.demandsupply.DemandSupplyProvider;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.vehicle.domain.VehicleType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.sql.Timestamp;
import java.time.Instant;

@Repository
public class PostgresDemandSupplyProvider implements DemandSupplyProvider {
    private final JdbcTemplate jdbc;
    private final DemandSupplyPricingProperties properties;

    public PostgresDemandSupplyProvider(JdbcTemplate jdbc, DemandSupplyPricingProperties properties) {
        this.jdbc = jdbc;
        this.properties = properties;
    }

    @Override
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ, timeout = 1)
    public DemandSupplyMetrics snapshot(GeoCoordinate pickup, VehicleType vehicleType, Instant evaluatedAt) {
        if (pickup == null || vehicleType == null || evaluatedAt == null) {
            throw new IllegalArgumentException("Pickup, vehicle type and evaluation time are required");
        }
        Instant demandCutoff = evaluatedAt.minus(properties.getLookback());
        Instant freshnessCutoff = evaluatedAt.minusSeconds(properties.getDriverLocationFreshnessSeconds());

        long demand = jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM bookings b
                WHERE b.status IN ('REQUESTED', 'SEARCHING_DRIVER')
                  AND b.assigned_driver_id IS NULL
                  AND b.assigned_vehicle_id IS NULL
                  AND b.vehicle_type = ?
                  AND b.created_at >= ? AND b.created_at <= ?
                  AND ST_DWithin(
                        b.pickup_location,
                        ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography,
                        ?
                  )
                """, Long.class, vehicleType.name(), ts(demandCutoff), ts(evaluatedAt),
                pickup.longitude().doubleValue(), pickup.latitude().doubleValue(), properties.getRadiusMeters());

        SupplyCounts supply = jdbc.queryForObject("""
                SELECT COUNT(DISTINCT d.id) FILTER (WHERE dl.updated_at >= ? AND dl.updated_at <= ?) AS fresh_count,
                       COUNT(DISTINCT d.id) AS eligible_count
                FROM driver_locations dl
                JOIN drivers d ON d.id = dl.driver_id
                JOIN vehicles v ON v.driver_id = d.id AND v.is_active = TRUE
                WHERE d.approval_status = 'APPROVED'
                  AND d.operating_status = 'ONLINE'
                  AND v.vehicle_type = ?
                  AND ST_DWithin(
                        dl.current_location,
                        ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography,
                        ?
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM booking_driver_offers pending
                      WHERE pending.driver_id = d.id AND pending.status = 'PENDING'
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM bookings assigned
                      WHERE assigned.assigned_driver_id = d.id AND assigned.driver_released_at IS NULL
                  )
                """, (rs, row) -> new SupplyCounts(rs.getLong("fresh_count"), rs.getLong("eligible_count")),
                ts(freshnessCutoff), ts(evaluatedAt), vehicleType.name(), pickup.longitude().doubleValue(),
                pickup.latitude().doubleValue(), properties.getRadiusMeters());

        return DemandSupplyMetrics.available(demand, supply.fresh(), supply.eligible(), supply.fresh());
    }

    private Timestamp ts(Instant value) {
        return Timestamp.from(value);
    }

    private record SupplyCounts(long fresh, long eligible) { }
}
