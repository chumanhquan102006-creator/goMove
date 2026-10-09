package com.gomove.trip.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.common.exception.DomainException;
import com.gomove.location.api.UpdateDriverLocationRequest;
import com.gomove.location.domain.DriverLocationRepository;
import com.gomove.trip.api.TrackingResponse;
import com.gomove.trip.api.TripTransitionResponse;
import com.gomove.trip.infrastructure.TripStore;
import com.gomove.trip.realtime.DriverLocationEvent;
import com.gomove.trip.realtime.TripStatusEvent;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Clock;
import java.time.Instant;
import java.util.UUID;

@Service
public class TripApplicationService {
    private final TripStore trips;
    private final DriverLocationRepository locations;
    private final ApplicationEventPublisher events;
    private final Clock clock;

    public TripApplicationService(TripStore trips, DriverLocationRepository locations,
                                  ApplicationEventPublisher events, Clock clock) {
        this.trips = trips;
        this.locations = locations;
        this.events = events;
        this.clock = clock;
    }

    @Transactional
    public TripTransitionResponse transition(UUID bookingPublicId, UUID driverUserPublicId,
                                             UserRole role, TripAction action) {
        requireDriver(role);
        TripStore.TripBooking booking = ownedDriverBooking(bookingPublicId, driverUserPublicId);
        if (booking.status() != action.expected()) {
            throw new DomainException(HttpStatus.CONFLICT, "TRIP_INVALID_STATE",
                    "Trip action is not valid in the current state");
        }
        Instant transitionedAt = trips.transition(booking.id(), action, clock.instant());
        events.publishEvent(new TripStatusEvent(bookingPublicId, action.target(), transitionedAt));
        return new TripTransitionResponse(bookingPublicId, action.target(), transitionedAt);
    }

    @Transactional
    public void updateRideLocation(UUID bookingPublicId, UUID driverUserPublicId,
                                   UserRole role, UpdateDriverLocationRequest request) {
        requireDriver(role);
        validateLocation(request);
        TripStore.TripBooking booking = ownedDriverBooking(bookingPublicId, driverUserPublicId);
        if (!TripStore.isTrackingStatus(booking.status())) {
            throw new DomainException(HttpStatus.CONFLICT, "TRIP_TRACKING_CLOSED",
                    "Trip is not accepting ride location updates");
        }
        // Server receipt order wins; the client supplies no timestamp. The Booking row lock
        // serializes ride updates with completion and other ride-location writes.
        Instant recordedAt = clock.instant();
        locations.upsertLatest(booking.driverId(), request.latitude(), request.longitude(),
                request.accuracy(), request.bearing(), recordedAt);
        events.publishEvent(new DriverLocationEvent(bookingPublicId, request.latitude(),
                request.longitude(), request.accuracy(), request.bearing(), recordedAt));
    }

    @Transactional(readOnly = true)
    public TrackingResponse tracking(UUID bookingPublicId, UUID userPublicId, UserRole role) {
        if (role != UserRole.CUSTOMER && role != UserRole.DRIVER) {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Tracking requires a trip participant");
        }
        return trips.tracking(bookingPublicId, userPublicId, role).map(TrackingResponse::from)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND,
                        "BOOKING_NOT_FOUND", "Booking not found"));
    }

    private TripStore.TripBooking ownedDriverBooking(UUID bookingPublicId, UUID driverUserPublicId) {
        return trips.assignedDriverBooking(bookingPublicId, driverUserPublicId, true)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND,
                        "BOOKING_NOT_FOUND", "Booking not found"));
    }

    private void requireDriver(UserRole role) {
        if (role != UserRole.DRIVER) {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Driver role is required");
        }
    }

    private void validateLocation(UpdateDriverLocationRequest request) {
        if (request == null || request.latitude() == null || request.longitude() == null
                || !Double.isFinite(request.latitude()) || request.latitude() < -90 || request.latitude() > 90
                || !Double.isFinite(request.longitude()) || request.longitude() < -180 || request.longitude() > 180
                || (request.accuracy() != null && (!Double.isFinite(request.accuracy()) || request.accuracy() < 0))
                || (request.bearing() != null && (!Double.isFinite(request.bearing())
                    || request.bearing() < 0 || request.bearing() >= 360))) {
            throw new DomainException(HttpStatus.BAD_REQUEST, "VALIDATION_ERROR", "Invalid ride location");
        }
    }
}
