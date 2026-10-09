package com.gomove.booking.api;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.gomove.booking.domain.Booking;
import com.gomove.booking.domain.BookingStatus;
import com.gomove.vehicle.domain.VehicleType;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

@JsonInclude(JsonInclude.Include.NON_NULL)
public record BookingResponse(
        UUID bookingPublicId,
        UUID quotePublicId,
        BookingStatus status,
        VehicleType vehicleType,
        String currency,
        BigDecimal finalFare,
        Instant createdAt,
        UUID driverPublicId,
        UUID vehiclePublicId,
        Instant driverAcceptedAt,
        Instant driverArrivedAt,
        Instant passengerOnboardAt,
        Instant tripStartedAt,
        Instant tripCompletedAt
) {
    public static BookingResponse from(Booking booking) {
        return new BookingResponse(booking.getPublicId(), booking.getQuote().getPublicId(),
                booking.getStatus(), booking.getVehicleType(), booking.getCurrencyCode(),
                booking.getFinalFare(), booking.getCreatedAt(),
                booking.getAssignedDriver() == null ? null : booking.getAssignedDriver().getPublicId(),
                booking.getAssignedVehicle() == null ? null : booking.getAssignedVehicle().getPublicId(),
                booking.getDriverAcceptedAt(), booking.getDriverArrivedAt(),
                booking.getPassengerOnboardAt(), booking.getTripStartedAt(), booking.getTripCompletedAt());
    }
}
