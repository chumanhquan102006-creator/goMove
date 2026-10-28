package com.gomove.booking.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.booking.domain.Booking;
import com.gomove.booking.domain.BookingRepository;
import com.gomove.common.exception.DomainException;
import com.gomove.pricing.api.RouteResponse;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

@Service
public class BookingRouteService {
    private final BookingRepository bookings;

    public BookingRouteService(BookingRepository bookings) {
        this.bookings = bookings;
    }

    @Transactional(readOnly = true)
    public RouteResponse getAuthorized(UUID bookingPublicId, UUID userPublicId, UserRole role) {
        Booking booking;
        if (role == UserRole.CUSTOMER) {
            booking = bookings.findOwned(bookingPublicId, userPublicId).orElseThrow(this::notFound);
        } else if (role == UserRole.DRIVER) {
            booking = bookings.findAssignedDriverRoute(bookingPublicId, userPublicId)
                    .orElseThrow(this::notFound);
        } else {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Trip participant role is required");
        }
        return RouteResponse.from(booking.getQuote(), booking.getPublicId());
    }

    private DomainException notFound() {
        return new DomainException(HttpStatus.NOT_FOUND, "BOOKING_NOT_FOUND", "Booking not found");
    }
}
