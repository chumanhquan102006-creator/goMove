package com.gomove.dispatch.service;

import com.gomove.booking.domain.BookingStatus;
import com.gomove.common.exception.DomainException;
import com.gomove.dispatch.api.OfferDecisionResponse;
import com.gomove.dispatch.infrastructure.DispatchStore;
import com.gomove.dispatch.domain.DriverOfferStatus;
import com.gomove.driver.domain.DriverApprovalStatus;
import com.gomove.driver.domain.DriverOperatingStatus;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Clock;
import java.time.Instant;
import java.util.UUID;

@Service
public class OfferTransactionService {
    private final DispatchStore store;
    private final Clock clock;

    public OfferTransactionService(DispatchStore store, Clock clock) {
        this.store = store;
        this.clock = clock;
    }

    @Transactional
    public OfferDecisionResponse accept(UUID driverUserPublicId, UUID offerPublicId) {
        store.boundLockWait();
        var reference = owned(offerPublicId, driverUserPublicId);
        // Shared order with dispatch: Booking -> Driver -> Vehicle -> Offer.
        var booking = store.lockBookingForAcceptance(reference.bookingId())
                .orElseThrow(() -> conflict("BOOKING_UNAVAILABLE", "Booking is unavailable"));
        var driver = store.lockDriver(reference.driverId())
                .orElseThrow(() -> conflict("DRIVER_UNAVAILABLE", "Driver is unavailable"));
        var vehicle = store.lockVehicle(reference.vehicleId())
                .orElseThrow(() -> conflict("VEHICLE_UNAVAILABLE", "Vehicle is unavailable"));
        var offer = store.lockOffer(reference.id())
                .orElseThrow(() -> conflict("OFFER_UNAVAILABLE", "Offer is unavailable"));
        Instant now = clock.instant(); // Strict deadline evaluated only after all locks are acquired.

        if (offer.status() != DriverOfferStatus.PENDING) {
            throw conflict("OFFER_NOT_PENDING", "Offer is no longer pending");
        }
        if (!now.isBefore(offer.expiresAt())) {
            throw conflict("OFFER_EXPIRED", "Offer has expired");
        }
        if (booking.status() != BookingStatus.SEARCHING_DRIVER
                || booking.assignedDriverId() != null || booking.assignedVehicleId() != null) {
            throw conflict("BOOKING_UNAVAILABLE", "Booking is no longer searching for a driver");
        }
        if (driver.approval() != DriverApprovalStatus.APPROVED
                || driver.operating() != DriverOperatingStatus.ONLINE
                || store.hasActiveAssignment(offer.driverId())) {
            throw conflict("DRIVER_UNAVAILABLE", "Driver is no longer eligible");
        }
        if (!vehicle.active() || !vehicle.driverId().equals(offer.driverId())
                || vehicle.type() != booking.vehicleType()) {
            throw conflict("VEHICLE_UNAVAILABLE", "Active vehicle is no longer eligible");
        }

        requireUpdated(store.finishValidOffer(offer.id(), DriverOfferStatus.ACCEPTED, clock.instant()));
        requireUpdated(store.assignBooking(booking.id(), offer.driverId(), offer.vehicleId(), now));
        requireUpdated(store.makeDriverBusy(offer.driverId(), now));
        return new OfferDecisionResponse(offerPublicId, DriverOfferStatus.ACCEPTED, now);
    }

    @Transactional
    public OfferDecisionResponse reject(UUID driverUserPublicId, UUID offerPublicId) {
        store.boundLockWait();
        var reference = owned(offerPublicId, driverUserPublicId);
        var booking = store.lockBookingForAcceptance(reference.bookingId())
                .orElseThrow(() -> conflict("BOOKING_UNAVAILABLE", "Booking is unavailable"));
        var offer = store.lockOffer(reference.id())
                .orElseThrow(() -> conflict("OFFER_UNAVAILABLE", "Offer is unavailable"));
        Instant now = clock.instant();
        if (offer.status() != DriverOfferStatus.PENDING) {
            throw conflict("OFFER_NOT_PENDING", "Offer is no longer pending");
        }
        if (!now.isBefore(offer.expiresAt())) {
            throw conflict("OFFER_EXPIRED", "Offer has expired");
        }
        if (booking.status() != BookingStatus.SEARCHING_DRIVER) {
            throw conflict("BOOKING_UNAVAILABLE", "Booking is no longer searching for a driver");
        }
        requireUpdated(store.finishValidOffer(offer.id(), DriverOfferStatus.REJECTED, clock.instant()));
        requireUpdated(store.reschedule(booking.id(), now, now));
        return new OfferDecisionResponse(offerPublicId, DriverOfferStatus.REJECTED, now);
    }

    private DispatchStore.Offer owned(UUID offerPublicId, UUID driverUserPublicId) {
        return store.ownedOffer(offerPublicId, driverUserPublicId)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND, "OFFER_NOT_FOUND", "Offer not found"));
    }

    private void requireUpdated(int count) {
        if (count != 1) throw conflict("OFFER_CONFLICT", "Offer changed concurrently");
    }

    private DomainException conflict(String code, String message) {
        return new DomainException(HttpStatus.CONFLICT, code, message);
    }
}
