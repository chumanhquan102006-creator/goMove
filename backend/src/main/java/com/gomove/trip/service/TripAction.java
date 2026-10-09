package com.gomove.trip.service;

import com.gomove.booking.domain.BookingStatus;

public enum TripAction {
    ARRIVE(BookingStatus.DRIVER_ACCEPTED, BookingStatus.DRIVER_ARRIVED, "driver_arrived_at", "driver_accepted_at"),
    ONBOARD(BookingStatus.DRIVER_ARRIVED, BookingStatus.PASSENGER_ONBOARD, "passenger_onboard_at", "driver_arrived_at"),
    START(BookingStatus.PASSENGER_ONBOARD, BookingStatus.IN_PROGRESS, "trip_started_at", "passenger_onboard_at"),
    COMPLETE(BookingStatus.IN_PROGRESS, BookingStatus.COMPLETED, "trip_completed_at", "trip_started_at");

    private final BookingStatus expected;
    private final BookingStatus target;
    private final String timestampColumn;
    private final String previousTimestampColumn;

    TripAction(BookingStatus expected, BookingStatus target, String timestampColumn, String previousTimestampColumn) {
        this.expected = expected;
        this.target = target;
        this.timestampColumn = timestampColumn;
        this.previousTimestampColumn = previousTimestampColumn;
    }

    public BookingStatus expected() { return expected; }
    public BookingStatus target() { return target; }
    public String timestampColumn() { return timestampColumn; }
    public String previousTimestampColumn() { return previousTimestampColumn; }
}
