package com.gomove.booking.api;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.gomove.booking.domain.BookingStatus;
import com.gomove.vehicle.domain.VehicleType;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

@JsonInclude(JsonInclude.Include.NON_NULL)
public record BookingHistoryItemResponse(
        UUID bookingPublicId,
        Instant createdAt,
        Instant tripCompletedAt,
        double pickupLatitude,
        double pickupLongitude,
        double dropoffLatitude,
        double dropoffLongitude,
        VehicleType vehicleType,
        BigDecimal finalFare,
        String currency,
        BookingStatus status,
        String paymentStatus
) {}
