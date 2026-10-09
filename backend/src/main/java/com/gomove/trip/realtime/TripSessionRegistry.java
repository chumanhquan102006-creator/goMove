package com.gomove.trip.realtime;

import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.messaging.SessionDisconnectEvent;

import java.time.Clock;
import java.time.Instant;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

@Component
public class TripSessionRegistry {
    private final ConcurrentMap<String, Instant> expiresAtBySession = new ConcurrentHashMap<>();
    private final Clock clock;

    public TripSessionRegistry(Clock clock) { this.clock = clock; }

    public boolean register(String sessionId, Instant expiresAt) {
        return sessionId != null && expiresAt != null && clock.instant().isBefore(expiresAt)
                && expiresAtBySession.putIfAbsent(sessionId, expiresAt) == null;
    }

    public boolean isCurrent(String sessionId) {
        Instant expiresAt = sessionId == null ? null : expiresAtBySession.get(sessionId);
        return expiresAt != null && clock.instant().isBefore(expiresAt);
    }

    public void remove(String sessionId) {
        if (sessionId != null) expiresAtBySession.remove(sessionId);
    }

    @EventListener
    public void disconnected(SessionDisconnectEvent event) { remove(event.getSessionId()); }
}
