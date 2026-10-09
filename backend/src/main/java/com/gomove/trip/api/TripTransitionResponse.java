package com.gomove.trip.api;

import com.gomove.booking.domain.BookingStatus;
import java.time.Instant;
import java.util.UUID;

public record TripTransitionResponse(UUID bookingPublicId, BookingStatus status, Instant transitionedAt) {}
