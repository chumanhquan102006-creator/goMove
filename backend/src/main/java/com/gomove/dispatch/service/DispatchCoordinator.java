package com.gomove.dispatch.service;

import com.gomove.dispatch.infrastructure.DispatchStore;
import org.springframework.stereotype.Service;

import java.time.Clock;

@Service
public class DispatchCoordinator {
    private final DispatchStore store;
    private final DispatchTransactionService transactions;
    private final DispatchProperties properties;
    private final Clock clock;

    public DispatchCoordinator(DispatchStore store, DispatchTransactionService transactions,
                               DispatchProperties properties, Clock clock) {
        this.store = store;
        this.transactions = transactions;
        this.properties = properties;
        this.clock = clock;
    }

    public int runBatch() {
        int limit = Math.max(1, Math.min(properties.getBatchSize(), 100));
        var due = store.dueBookings(clock.instant(), limit);
        for (Long bookingId : due) transactions.advance(bookingId); // One short transaction per Booking.
        return due.size();
    }
}
