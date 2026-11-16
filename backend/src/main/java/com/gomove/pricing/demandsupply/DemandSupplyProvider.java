package com.gomove.pricing.demandsupply;

import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.vehicle.domain.VehicleType;

import java.time.Instant;

public interface DemandSupplyProvider {
    DemandSupplyMetrics snapshot(GeoCoordinate pickup, VehicleType vehicleType, Instant evaluatedAt);
}
