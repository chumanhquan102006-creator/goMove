package com.gomove.trip.realtime;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.messaging.simp.SimpMessagingTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.event.TransactionPhase;
import org.springframework.transaction.event.TransactionalEventListener;

@Component
public class TripEventDelivery {
    private static final Logger log = LoggerFactory.getLogger(TripEventDelivery.class);
    private final SimpMessagingTemplate messaging;

    public TripEventDelivery(SimpMessagingTemplate messaging) { this.messaging = messaging; }

    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void status(TripStatusEvent event) { deliver(event.bookingPublicId().toString(), event); }

    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void location(DriverLocationEvent event) { deliver(event.bookingPublicId().toString(), event); }

    private void deliver(String bookingPublicId, Object event) {
        try {
            messaging.convertAndSend("/topic/ride/" + bookingPublicId, event);
        } catch (RuntimeException ex) {
            // The database has committed. Reconnection uses GET /tracking as the durable source.
            log.warn("Trip event delivery failed for booking {}", bookingPublicId, ex);
        }
    }
}
