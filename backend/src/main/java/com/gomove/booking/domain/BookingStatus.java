package com.gomove.booking.domain;

public enum BookingStatus {
    REQUESTED,
    SEARCHING_DRIVER,
    DRIVER_ACCEPTED,
    DRIVER_ARRIVED,
    PASSENGER_ONBOARD,
    IN_PROGRESS,
    COMPLETED,
    CANCELLED,
    NO_DRIVER_AVAILABLE
}
