package com.gomove.trip.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.booking.domain.BookingStatus;
import com.gomove.common.exception.DomainException;
import com.gomove.location.infrastructure.LocationProperties;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.routing.RoutingService;
import com.gomove.trip.api.TripEtaResponse;
import com.gomove.trip.infrastructure.TripStore;
import com.gomove.trip.infrastructure.TripStore.EtaSnapshot;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;

import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class TripEtaServiceTest {
    private static final UUID BOOKING = UUID.randomUUID();
    private static final UUID CUSTOMER = UUID.randomUUID();
    private static final Instant START = Instant.parse("2026-10-28T03:00:00Z");
    private final TripStore store = mock(TripStore.class);
    private final RoutingService routing = mock(RoutingService.class);
    private final Clock clock = mock(Clock.class);
    private final AtomicReference<Instant> now = new AtomicReference<>(START);
    private final AtomicReference<EtaSnapshot> snapshot = new AtomicReference<>();
    private TripEtaService service;

    @BeforeEach
    void setUp() {
        LocationProperties properties = new LocationProperties();
        service = new TripEtaService(store, routing, properties, clock);
        snapshot.set(active(BookingStatus.DRIVER_ACCEPTED, 21.0287, 105.8524, 8.0, START));
        when(clock.instant()).thenAnswer(invocation -> now.get());
        when(store.etaSnapshot(BOOKING, CUSTOMER, UserRole.CUSTOMER))
                .thenAnswer(invocation -> Optional.ofNullable(snapshot.get()));
        when(routing.calculateTravelMetrics(any(), any())).thenReturn(metrics());
    }

    @Test
    void pickupAndDestinationUseRoadRoutingWithLatitudeLongitudeAtTheApiBoundary() {
        TripEtaResponse pickup = service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER);
        assertThat(pickup.phase()).isEqualTo(TripEtaResponse.Phase.PICKUP);
        assertThat(pickup.availability()).isEqualTo(TripEtaResponse.Availability.AVAILABLE);
        assertThat(pickup.durationSeconds()).isEqualByComparingTo("123.500");
        assertThat(pickup.distanceMeters()).isEqualByComparingTo("754.300");
        assertThat(pickup.locationUpdatedAt()).isEqualTo(START);
        assertThat(pickup.expiresAt()).isEqualTo(START.plusSeconds(30));
        assertThat(pickup.servedAt()).isEqualTo(START);
        verify(routing).calculateTravelMetrics(
                eq(new GeoCoordinate(new BigDecimal("21.0287"), new BigDecimal("105.8524"))),
                eq(new GeoCoordinate(new BigDecimal("21.03"), new BigDecimal("105.85"))));

        snapshot.set(active(BookingStatus.IN_PROGRESS, 21.0270, 105.8540, 8.0, START));
        TripEtaResponse destination = service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER);
        assertThat(destination.phase()).isEqualTo(TripEtaResponse.Phase.DESTINATION);
        verify(routing).calculateTravelMetrics(
                eq(new GeoCoordinate(new BigDecimal("21.027"), new BigDecimal("105.854"))),
                eq(new GeoCoordinate(new BigDecimal("21.0245"), new BigDecimal("105.8576"))));
    }

    @Test
    void unavailableWhenGpsIsMissingStaleOrInaccurate() {
        snapshot.set(active(BookingStatus.DRIVER_ACCEPTED, null, null, null, null));
        assertThat(service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER).reason())
                .isEqualTo(TripEtaResponse.Reason.GPS_UNAVAILABLE);
        snapshot.set(active(BookingStatus.DRIVER_ACCEPTED, 21.0287, 105.8524, 8.0,
                START.minusSeconds(31)));
        assertThat(service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER).reason())
                .isEqualTo(TripEtaResponse.Reason.GPS_STALE);
        snapshot.set(active(BookingStatus.DRIVER_ACCEPTED, 21.0287, 105.8524, 101.0, START));
        assertThat(service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER).reason())
                .isEqualTo(TripEtaResponse.Reason.GPS_INACCURATE);
        snapshot.set(active(BookingStatus.DRIVER_ACCEPTED, 21.0287, 105.8524, null, START));
        assertThat(service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER).reason())
                .isEqualTo(TripEtaResponse.Reason.GPS_INACCURATE);
        verifyNoInteractions(routing);
    }

    @Test
    void cacheRequiresMeaningfulMovementAndFifteenSecondsButNeverOutlivesSourceGps() {
        service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER);
        now.set(START.plusSeconds(14));
        snapshot.set(active(BookingStatus.DRIVER_ACCEPTED, 21.0297, 105.8524, 8.0, now.get()));
        TripEtaResponse cached = service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER);
        assertThat(cached.locationUpdatedAt()).isEqualTo(START);
        assertThat(cached.servedAt()).isEqualTo(START.plusSeconds(14));
        verify(routing, times(1)).calculateTravelMetrics(any(), any());

        now.set(START.plusSeconds(16));
        TripEtaResponse refreshed = service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER);
        assertThat(refreshed.locationUpdatedAt()).isEqualTo(START.plusSeconds(14));
        verify(routing, times(2)).calculateTravelMetrics(any(), any());

        now.set(START.plusSeconds(45));
        assertThat(service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER).reason())
                .isEqualTo(TripEtaResponse.Reason.GPS_STALE);
        verify(routing, times(2)).calculateTravelMetrics(any(), any());
    }

    @Test
    void routeFailureIsUnavailableAndRateLimitedWithoutHidingNewTripStatus() {
        when(routing.calculateTravelMetrics(any(), any()))
                .thenThrow(new DomainException(HttpStatus.SERVICE_UNAVAILABLE,
                        "ROUTING_UNAVAILABLE", "Road routing is temporarily unavailable"));
        assertThat(service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER).reason())
                .isEqualTo(TripEtaResponse.Reason.ROUTING_UNAVAILABLE);
        now.set(START.plusSeconds(9));
        assertThat(service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER).reason())
                .isEqualTo(TripEtaResponse.Reason.ROUTING_UNAVAILABLE);
        verify(routing, times(1)).calculateTravelMetrics(any(), any());
        snapshot.set(active(BookingStatus.COMPLETED, null, null, null, null));
        TripEtaResponse completed = service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER);
        assertThat(completed.status()).isEqualTo(BookingStatus.COMPLETED);
        assertThat(completed.phase()).isEqualTo(TripEtaResponse.Phase.NONE);
        assertThat(completed.reason()).isEqualTo(TripEtaResponse.Reason.NOT_APPLICABLE);
        assertThat(completed.locationUpdatedAt()).isNull();
    }

    @Test
    void completionDuringSlowRoutingDiscardsResultAndDoesNotCacheOldGps() {
        when(routing.calculateTravelMetrics(any(), any())).thenAnswer(invocation -> {
            snapshot.set(active(BookingStatus.COMPLETED, null, null, null, null));
            return metrics();
        });
        TripEtaResponse response = service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER);
        assertThat(response.status()).isEqualTo(BookingStatus.COMPLETED);
        assertThat(response.availability()).isEqualTo(TripEtaResponse.Availability.UNAVAILABLE);
        assertThat(response.locationUpdatedAt()).isNull();
        assertThat(response.distanceMeters()).isNull();
        service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER);
        verify(routing, times(1)).calculateTravelMetrics(any(), any());
    }

    @Test
    void completedDuringFailedRoutingStillReportsCurrentState() {
        when(routing.calculateTravelMetrics(any(), any())).thenAnswer(invocation -> {
            snapshot.set(active(BookingStatus.COMPLETED, null, null, null, null));
            throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "ROUTING_UNAVAILABLE", "timeout");
        });
        assertThat(service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER).status())
                .isEqualTo(BookingStatus.COMPLETED);
    }

    @Test
    void unauthorizedOrUnknownBookingNeverCallsRouting() {
        assertThatThrownBy(() -> service.get(BOOKING, CUSTOMER, UserRole.ADMIN))
                .isInstanceOf(DomainException.class)
                .extracting(ex -> ((DomainException) ex).getCode()).isEqualTo("FORBIDDEN");
        snapshot.set(null);
        assertThatThrownBy(() -> service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER))
                .isInstanceOf(DomainException.class)
                .extracting(ex -> ((DomainException) ex).getCode()).isEqualTo("BOOKING_NOT_FOUND");
        verifyNoInteractions(routing);
    }

    @Test
    void concurrentPollsForSameBookingMakeOneRoadRequest() throws Exception {
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        when(routing.calculateTravelMetrics(any(), any())).thenAnswer(invocation -> {
            entered.countDown();
            assertThat(release.await(5, TimeUnit.SECONDS)).isTrue();
            return metrics();
        });
        var pool = Executors.newFixedThreadPool(2);
        try {
            var first = pool.submit(() -> service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER));
            assertThat(entered.await(5, TimeUnit.SECONDS)).isTrue();
            var second = pool.submit(() -> service.get(BOOKING, CUSTOMER, UserRole.CUSTOMER));
            release.countDown();
            assertThat(first.get(5, TimeUnit.SECONDS).availability())
                    .isEqualTo(TripEtaResponse.Availability.AVAILABLE);
            assertThat(second.get(5, TimeUnit.SECONDS).availability())
                    .isEqualTo(TripEtaResponse.Availability.AVAILABLE);
            verify(routing, times(1)).calculateTravelMetrics(any(), any());
        } finally {
            release.countDown();
            pool.shutdownNow();
        }
    }

    private EtaSnapshot active(BookingStatus status, Double latitude, Double longitude,
                               Double accuracy, Instant updatedAt) {
        return new EtaSnapshot(status, 11L, 21.0300, 105.8500, 21.0245, 105.8576,
                latitude, longitude, accuracy, updatedAt);
    }

    private RouteEstimate metrics() {
        return new RouteEstimate(new BigDecimal("754.3"), new BigDecimal("123.5"), "OSRM");
    }
}
