package com.gomove.pricing.demandsupply;

import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.vehicle.domain.VehicleType;
import org.springframework.dao.DataAccessException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.TransactionException;

import java.time.Instant;

@Service
public class DemandSupplyPricingService {
    private final DemandSupplyPricingProperties properties;
    private final DemandSupplyProvider provider;
    private final DemandSupplyPricingPolicy policy;

    public DemandSupplyPricingService(DemandSupplyPricingProperties properties,
                                      DemandSupplyProvider provider,
                                      DemandSupplyPricingPolicy policy) {
        this.properties = properties;
        this.provider = provider;
        this.policy = policy;
    }

    /** Disabled pricing avoids every demand/supply database query and leaves the prior snapshot unchanged. */
    public DemandSupplyPricingPolicy.Evaluation evaluate(Instant evaluatedAt,
                                                        GeoCoordinate pickup,
                                                        VehicleType vehicleType) {
        if (!properties.isEnabled()) return null;
        DemandSupplyMetrics metrics;
        try {
            metrics = provider.snapshot(pickup, vehicleType, evaluatedAt);
        } catch (DataAccessException | TransactionException ex) {
            metrics = DemandSupplyMetrics.unavailable();
        }
        return policy.evaluate(evaluatedAt, metrics);
    }
}
