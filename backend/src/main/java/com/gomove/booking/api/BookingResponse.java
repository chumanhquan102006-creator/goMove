package com.gomove.booking.api;

import com.gomove.booking.domain.Booking;
import com.gomove.booking.domain.BookingStatus;
import com.gomove.vehicle.domain.VehicleType;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

public record BookingResponse(
        UUID bookingPublicId,
        UUID quotePublicId,
        BookingStatus status,
        VehicleType vehicleType,
        String currency,
        BigDecimal finalFare,
        Instant createdAt
) {
    public static BookingResponse from(Booking booking) {
        return new BookingResponse(booking.getPublicId(), booking.getQuote().getPublicId(),
                booking.getStatus(), booking.getVehicleType(), booking.getCurrencyCode(),
                booking.getFinalFare(), booking.getCreatedAt());
    }
}
