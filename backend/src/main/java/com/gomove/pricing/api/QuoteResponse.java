package com.gomove.pricing.api;

import com.gomove.pricing.domain.Quote;
import com.gomove.pricing.domain.QuoteStatus;
import com.gomove.vehicle.domain.VehicleType;
import io.swagger.v3.oas.annotations.media.Schema;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

@Schema(description = "Original fare breakdown. finalFare = baseFare + distanceFare + timeFare + surcharge + surgeAmount - discountAmount + roundingAdjustment. surgeAmount applies the multiplier to the unrounded subtotal. An ISSUED quote is usable only before expiresAt; expired quotes are shown as EXPIRED without a background update.")
public record QuoteResponse(
        UUID quotePublicId,
        CoordinateResponse pickup,
        CoordinateResponse dropoff,
        VehicleType vehicleType,
        BigDecimal distanceMeters,
        BigDecimal durationSeconds,
        String routingProvider,
        String currency,
        BigDecimal baseFare,
        BigDecimal distanceFare,
        BigDecimal timeFare,
        BigDecimal surcharge,
        BigDecimal surgeMultiplier,
        BigDecimal surgeAmount,
        BigDecimal discountAmount,
        BigDecimal roundingAdjustment,
        BigDecimal finalFare,
        String pricingEngineVersion,
        QuoteStatus status,
        Instant issuedAt,
        Instant expiresAt
) {
    public static QuoteResponse from(Quote quote, Instant now) {
        return new QuoteResponse(
                quote.getPublicId(),
                new CoordinateResponse(quote.getPickupLocation().getY(), quote.getPickupLocation().getX()),
                new CoordinateResponse(quote.getDropoffLocation().getY(), quote.getDropoffLocation().getX()),
                quote.getVehicleType(), quote.getDistanceMeters(), quote.getDurationSeconds(),
                quote.getRoutingProvider(),
                quote.getCurrencyCode(), quote.getBaseFare(), quote.getDistanceFare(),
                quote.getTimeFare(), quote.getSurcharge(), quote.getSurgeMultiplier(),
                quote.getSurgeAmount(), quote.getDiscountAmount(), quote.getRoundingAdjustment(),
                quote.getFinalFare(), quote.getPricingEngineVersion(),
                quote.effectiveStatus(now), quote.getIssuedAt(), quote.getExpiresAt());
    }

    public record CoordinateResponse(double latitude, double longitude) {
    }
}
