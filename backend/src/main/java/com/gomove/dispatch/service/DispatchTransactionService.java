package com.gomove.dispatch.service;

import com.gomove.booking.domain.BookingStatus;
import com.gomove.dispatch.infrastructure.DispatchStore;
import com.gomove.dispatch.domain.DriverOfferStatus;
import com.gomove.location.infrastructure.LocationProperties;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Clock;
import java.time.Instant;

@Service
public class DispatchTransactionService {
    private final DispatchStore store;
    private final DispatchProperties properties;
    private final LocationProperties locationProperties;
    private final Clock clock;

    public DispatchTransactionService(DispatchStore store, DispatchProperties properties,
                                      LocationProperties locationProperties, Clock clock) {
        this.store = store;
        this.properties = properties;
        this.locationProperties = locationProperties;
        this.clock = clock;
    }

    @Transactional
    public void advance(Long bookingId) {
        // Lock order: Booking -> candidate Driver/Vehicle -> Offer. Acceptance uses the same order.
        store.boundLockWait();
        var locked = store.lockBooking(bookingId);
        if (locked.isEmpty()) return; // Another worker owns the row (SKIP LOCKED).
        var booking = locked.get();
        if (booking.status() != BookingStatus.REQUESTED && booking.status() != BookingStatus.SEARCHING_DRIVER) return;
        if (booking.assignedDriverId() != null || booking.assignedVehicleId() != null) {
            throw new IllegalStateException("Unaccepted Booking has an assignment");
        }

        Instant now = clock.instant();
        var pending = store.pendingForBooking(bookingId);
        if (pending.isPresent()) {
            if (now.isBefore(pending.get().expiresAt())) {
                requireUpdated(store.scheduleSearch(bookingId, pending.get().expiresAt(), now));
                return;
            }
            requireUpdated(store.finishOffer(pending.get().id(), DriverOfferStatus.EXPIRED, now));
        }

        var candidate = store.nearestCandidate(bookingId,
                now.minusSeconds(locationProperties.getDispatchFreshnessSeconds()),
                properties.getRadiusMeters());
        if (candidate.isPresent()) {
            // The query owns the Driver lock; acquire Vehicle next, then recheck mutable eligibility.
            var vehicle = store.lockVehicle(candidate.get().vehicleId());
            if (vehicle.isEmpty() || !vehicle.get().active()
                    || !vehicle.get().driverId().equals(candidate.get().driverId())
                    || vehicle.get().type() != booking.vehicleType()
                    || store.hasActiveAssignment(candidate.get().driverId())) {
                requireUpdated(store.scheduleSearch(bookingId, now.plusSeconds(properties.getRetrySeconds()), now));
                return;
            }
            Instant offeredAt = clock.instant();
            if (store.createOffer(bookingId, candidate.get(), offeredAt)) {
                requireUpdated(store.scheduleSearch(bookingId, offeredAt.plusSeconds(15), offeredAt));
            } else {
                requireUpdated(store.scheduleSearch(bookingId,
                        offeredAt.plusSeconds(properties.getRetrySeconds()), offeredAt));
            }
        } else {
            requireUpdated(store.scheduleSearch(bookingId, now.plusSeconds(properties.getRetrySeconds()), now));
        }
    }

    private void requireUpdated(int count) {
        if (count != 1) throw new IllegalStateException("Dispatch state changed unexpectedly");
    }
}
