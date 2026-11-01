package com.gomove.geocoding.service;

import com.gomove.common.exception.DomainException;
import com.gomove.geocoding.infrastructure.GeocodingProperties;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.function.LongSupplier;

/** A bounded, per-account limit shared only by place search and reverse lookup. */
@Component
public class GeocodingRateLimiter {
    private static final int MAX_TRACKED_ACCOUNTS = 1_024;
    private final int maxRequests;
    private final long windowNanos;
    private final LongSupplier clock;
    private final Map<UUID, Window> windows = new HashMap<>();

    private record Window(long startedAt, int count) { }

    @Autowired
    public GeocodingRateLimiter(GeocodingProperties properties) {
        this(properties, System::nanoTime);
    }

    GeocodingRateLimiter(GeocodingProperties properties, LongSupplier clock) {
        Duration window = properties.getRateWindow();
        if (properties.getMaxRequests() < 1 || properties.getMaxRequests() > 120
                || window == null || window.compareTo(Duration.ofSeconds(1)) < 0
                || window.compareTo(Duration.ofHours(1)) > 0) {
            throw new IllegalArgumentException("Geocoding rate limit must be 1..120 requests per 1s..1h window");
        }
        this.maxRequests = properties.getMaxRequests();
        this.windowNanos = window.toNanos();
        this.clock = clock;
    }

    public synchronized void check(UUID accountPublicId) {
        if (accountPublicId == null) throw new IllegalArgumentException("Authenticated account required");
        long now = clock.getAsLong();
        Window current = windows.get(accountPublicId);
        if (current == null || now - current.startedAt() >= windowNanos) {
            if (current == null && windows.size() >= MAX_TRACKED_ACCOUNTS) {
                windows.entrySet().removeIf(entry -> now - entry.getValue().startedAt() >= windowNanos);
                if (windows.size() >= MAX_TRACKED_ACCOUNTS) throw rateLimited();
            }
            windows.put(accountPublicId, new Window(now, 1));
            return;
        }
        if (current.count() >= maxRequests) throw rateLimited();
        windows.put(accountPublicId, new Window(current.startedAt(), current.count() + 1));
    }

    private DomainException rateLimited() {
        return new DomainException(HttpStatus.TOO_MANY_REQUESTS,
                "GEOCODING_RATE_LIMITED", "Address lookup is rate limited");
    }
}
