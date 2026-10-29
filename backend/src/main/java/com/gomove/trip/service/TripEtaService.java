package com.gomove.trip.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.booking.domain.BookingStatus;
import com.gomove.common.exception.DomainException;
import com.gomove.location.infrastructure.LocationProperties;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.routing.RoutingService;
import com.gomove.trip.api.TripEtaResponse;
import com.gomove.trip.api.TripEtaResponse.Availability;
import com.gomove.trip.api.TripEtaResponse.Phase;
import com.gomove.trip.api.TripEtaResponse.Reason;
import com.gomove.trip.infrastructure.TripStore;
import com.gomove.trip.infrastructure.TripStore.EtaSnapshot;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

@Service
public class TripEtaService {
    // A fixed set of locks and a bounded cache avoid duplicate OSRM calls on concurrent polls.
    // Routing is outside any database transaction. The response always rechecks live DB state.
    private static final int CACHE_LIMIT = 256;
    private static final int LOCK_STRIPES = 64;
    private static final Duration MIN_REFRESH = Duration.ofSeconds(15);
    private static final Duration MAX_AGE = Duration.ofSeconds(30);
    private static final double MIN_MOVEMENT_METERS = 50;
    private static final double MAX_ACCURACY_METERS = 100;

    private final TripStore trips;
    private final RoutingService routing;
    private final LocationProperties locationProperties;
    private final Clock clock;
    private final ConcurrentHashMap<UUID, CacheEntry> cache = new ConcurrentHashMap<>();
    private final Object[] locks = new Object[LOCK_STRIPES];
    private final Object cacheGuard = new Object();

    public TripEtaService(TripStore trips, RoutingService routing,
                          LocationProperties locationProperties, Clock clock) {
        this.trips = trips;
        this.routing = routing;
        this.locationProperties = locationProperties;
        this.clock = clock;
        for (int i = 0; i < locks.length; i++) locks[i] = new Object();
    }

    public TripEtaResponse get(UUID bookingPublicId, UUID userPublicId, UserRole role) {
        if (role != UserRole.CUSTOMER && role != UserRole.DRIVER) {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Trip participant role is required");
        }
        Object lock = locks[Math.floorMod(bookingPublicId.hashCode(), LOCK_STRIPES)];
        synchronized (lock) {
            EtaSnapshot snapshot = authorizedSnapshot(bookingPublicId, userPublicId, role);
            Phase phase = phase(snapshot.status());
            if (phase == Phase.NONE) {
                cache.remove(bookingPublicId);
                return unavailable(bookingPublicId, snapshot.status(), phase, Reason.NOT_APPLICABLE);
            }
            Instant now = clock.instant();
            Reason locationProblem = locationProblem(snapshot, now);
            if (locationProblem != null) {
                cache.remove(bookingPublicId);
                return unavailable(bookingPublicId, snapshot.status(), phase, locationProblem);
            }
            CacheEntry previous = cache.get(bookingPublicId);
            if (previous != null && previous.canReuse(snapshot, phase, now)) {
                return previous.response().withServedAt(now);
            }

            GeoCoordinate origin = coordinate(snapshot.driverLatitude(), snapshot.driverLongitude());
            GeoCoordinate target = target(snapshot, phase);
            RouteEstimate estimate;
            try {
                estimate = routing.calculateTravelMetrics(origin, target);
                if (estimate == null || estimate.distanceMeters() == null
                        || estimate.durationSeconds() == null) throw new IllegalArgumentException("Missing ETA metrics");
            } catch (DomainException | IllegalArgumentException ex) {
                EtaSnapshot current = authorizedSnapshot(bookingPublicId, userPublicId, role);
                Phase currentPhase = phase(current.status());
                if (current.status() != snapshot.status()
                        || !java.util.Objects.equals(current.assignedDriverId(), snapshot.assignedDriverId())) {
                    cache.remove(bookingPublicId);
                    return unavailable(bookingPublicId, current.status(), currentPhase,
                            currentPhase == Phase.NONE ? Reason.NOT_APPLICABLE : Reason.ROUTING_UNAVAILABLE);
                }
                Reason currentProblem = locationProblem(current, clock.instant());
                if (currentProblem != null) {
                    cache.remove(bookingPublicId);
                    return unavailable(bookingPublicId, current.status(), currentPhase, currentProblem);
                }
                TripEtaResponse unavailable = unavailable(bookingPublicId, snapshot.status(), phase,
                        Reason.ROUTING_UNAVAILABLE);
                store(bookingPublicId, new CacheEntry(snapshot, phase, unavailable, now));
                return unavailable;
            }

            // A completion or materially newer GPS fix during the HTTP call invalidates the result.
            EtaSnapshot current = authorizedSnapshot(bookingPublicId, userPublicId, role);
            Instant calculatedAt = clock.instant();
            Phase currentPhase = phase(current.status());
            if (current.status() != snapshot.status() || current.assignedDriverId() == null
                    || !current.assignedDriverId().equals(snapshot.assignedDriverId())) {
                cache.remove(bookingPublicId);
                return unavailable(bookingPublicId, current.status(), currentPhase,
                        currentPhase == Phase.NONE ? Reason.NOT_APPLICABLE : Reason.ROUTING_UNAVAILABLE);
            }
            Reason currentProblem = locationProblem(current, calculatedAt);
            if (currentProblem != null) {
                cache.remove(bookingPublicId);
                return unavailable(bookingPublicId, current.status(), currentPhase, currentProblem);
            }
            if (movementMeters(snapshot, current) >= MIN_MOVEMENT_METERS) {
                cache.remove(bookingPublicId);
                return unavailable(bookingPublicId, current.status(), currentPhase, Reason.GPS_UNAVAILABLE);
            }
            Instant expiresAt = earlier(calculatedAt.plus(MAX_AGE),
                    snapshot.locationUpdatedAt().plusSeconds(locationProperties.getDispatchFreshnessSeconds()));
            if (!calculatedAt.isBefore(expiresAt)) {
                return unavailable(bookingPublicId, current.status(), currentPhase, Reason.GPS_STALE);
            }
            TripEtaResponse response = new TripEtaResponse(bookingPublicId, current.status(), phase,
                    Availability.AVAILABLE, null, estimate.distanceMeters(), estimate.durationSeconds(),
                    calculatedAt, snapshot.locationUpdatedAt(), expiresAt, calculatedAt);
            store(bookingPublicId, new CacheEntry(snapshot, phase, response, calculatedAt));
            return response;
        }
    }

    private EtaSnapshot authorizedSnapshot(UUID bookingPublicId, UUID userPublicId, UserRole role) {
        return trips.etaSnapshot(bookingPublicId, userPublicId, role)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND,
                        "BOOKING_NOT_FOUND", "Booking not found"));
    }

    private Phase phase(BookingStatus status) {
        return switch (status) {
            case DRIVER_ACCEPTED -> Phase.PICKUP;
            case IN_PROGRESS -> Phase.DESTINATION;
            default -> Phase.NONE;
        };
    }

    private Reason locationProblem(EtaSnapshot snapshot, Instant now) {
        if (snapshot.driverLatitude() == null || snapshot.driverLongitude() == null
                || snapshot.locationUpdatedAt() == null
                || !Double.isFinite(snapshot.driverLatitude()) || !Double.isFinite(snapshot.driverLongitude())
                || snapshot.driverLatitude() < -90 || snapshot.driverLatitude() > 90
                || snapshot.driverLongitude() < -180 || snapshot.driverLongitude() > 180) {
            return Reason.GPS_UNAVAILABLE;
        }
        Duration age = Duration.between(snapshot.locationUpdatedAt(), now);
        if (age.isNegative() || age.compareTo(Duration.ofSeconds(locationProperties.getDispatchFreshnessSeconds())) > 0) {
            return Reason.GPS_STALE;
        }
        if (snapshot.accuracy() == null || !Double.isFinite(snapshot.accuracy())
                || snapshot.accuracy() < 0 || snapshot.accuracy() > MAX_ACCURACY_METERS) {
            return Reason.GPS_INACCURATE;
        }
        return null;
    }

    private GeoCoordinate coordinate(double latitude, double longitude) {
        return new GeoCoordinate(BigDecimal.valueOf(latitude), BigDecimal.valueOf(longitude));
    }

    private GeoCoordinate target(EtaSnapshot snapshot, Phase phase) {
        return phase == Phase.PICKUP
                ? coordinate(snapshot.pickupLatitude(), snapshot.pickupLongitude())
                : coordinate(snapshot.dropoffLatitude(), snapshot.dropoffLongitude());
    }

    private double movementMeters(EtaSnapshot first, EtaSnapshot second) {
        double lat1 = Math.toRadians(first.driverLatitude());
        double lat2 = Math.toRadians(second.driverLatitude());
        double dLat = lat2 - lat1;
        double dLon = Math.toRadians(second.driverLongitude() - first.driverLongitude());
        double a = Math.pow(Math.sin(dLat / 2), 2)
                + Math.cos(lat1) * Math.cos(lat2) * Math.pow(Math.sin(dLon / 2), 2);
        return 2 * 6_371_000 * Math.asin(Math.min(1, Math.sqrt(a)));
    }

    private Instant earlier(Instant first, Instant second) {
        return first.isBefore(second) ? first : second;
    }

    private TripEtaResponse unavailable(UUID bookingPublicId, BookingStatus status, Phase phase, Reason reason) {
        return new TripEtaResponse(bookingPublicId, status, phase, Availability.UNAVAILABLE,
                reason, null, null, null, null, null, clock.instant());
    }

    private void store(UUID bookingPublicId, CacheEntry entry) {
        synchronized (cacheGuard) {
            if (cache.size() >= CACHE_LIMIT && !cache.containsKey(bookingPublicId)) {
                UUID oldest = cache.keys().nextElement();
                cache.remove(oldest);
            }
            cache.put(bookingPublicId, entry);
        }
    }

    private record CacheEntry(EtaSnapshot source, Phase phase, TripEtaResponse response, Instant attemptedAt) {
        boolean canReuse(EtaSnapshot current, Phase currentPhase, Instant now) {
            if (currentPhase != phase || current.status() != source.status()
                    || !java.util.Objects.equals(current.assignedDriverId(), source.assignedDriverId())) return false;
            if (response.availability() == Availability.UNAVAILABLE) {
                return now.isBefore(attemptedAt.plus(MIN_REFRESH));
            }
            return now.isBefore(response.expiresAt())
                    && (now.isBefore(attemptedAt.plus(MIN_REFRESH))
                    || move(source, current) < MIN_MOVEMENT_METERS);
        }

        private double move(EtaSnapshot first, EtaSnapshot second) {
            double lat1 = Math.toRadians(first.driverLatitude());
            double lat2 = Math.toRadians(second.driverLatitude());
            double dLat = lat2 - lat1;
            double dLon = Math.toRadians(second.driverLongitude() - first.driverLongitude());
            double a = Math.pow(Math.sin(dLat / 2), 2)
                    + Math.cos(lat1) * Math.cos(lat2) * Math.pow(Math.sin(dLon / 2), 2);
            return 2 * 6_371_000 * Math.asin(Math.min(1, Math.sqrt(a)));
        }
    }
}
