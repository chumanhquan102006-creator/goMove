package com.gomove.dispatch.api;

import com.gomove.dispatch.infrastructure.DispatchStore;
import com.gomove.vehicle.domain.VehicleType;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

public record DriverOfferResponse(UUID offerPublicId, UUID bookingPublicId,
                                  double pickupLatitude, double pickupLongitude,
                                  double dropoffLatitude, double dropoffLongitude,
                                  VehicleType vehicleType, String currency, BigDecimal finalFare,
                                  Instant offeredAt, Instant expiresAt) {
    public static DriverOfferResponse from(DispatchStore.ActiveOffer offer) {
        return new DriverOfferResponse(offer.offerPublicId(), offer.bookingPublicId(),
                offer.pickupLatitude(), offer.pickupLongitude(),
                offer.dropoffLatitude(), offer.dropoffLongitude(),
                offer.vehicleType(), offer.currency(), offer.finalFare(),
                offer.offeredAt(), offer.expiresAt());
    }
}
