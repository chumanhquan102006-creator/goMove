package com.gomove.geocoding.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.common.exception.DomainException;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.geocoding.api.GeocodingController;
import com.gomove.geocoding.infrastructure.GeocodingProperties;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;

import java.time.Duration;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class GeocodingRateLimiterTest {
    private final AtomicLong now = new AtomicLong();

    @Test
    void searchAndReverseSharePerAccountBudgetAndResetAtWindowBoundary() {
        GeocodingRateLimiter limiter = limiter(2, Duration.ofSeconds(10));
        GeocodingService service = mock(GeocodingService.class);
        when(service.search("Hà Nội")).thenReturn(List.of());
        GeocodingController controller = new GeocodingController(service, limiter);
        var customer = new CustomUserPrincipal(UUID.randomUUID(), UserRole.CUSTOMER);
        var other = new CustomUserPrincipal(UUID.randomUUID(), UserRole.CUSTOMER);

        controller.search("Hà Nội", customer);
        controller.reverse("21.02", "105.85", customer);
        assertRateLimited(() -> controller.search("Hà Nội", customer));
        verify(service, times(1)).search("Hà Nội");
        verify(service, times(1)).reverse("21.02", "105.85");

        controller.search("Hà Nội", other);
        now.set(Duration.ofSeconds(10).toNanos());
        controller.search("Hà Nội", customer);
        verify(service, times(3)).search("Hà Nội");
    }

    @Test
    void concurrentRequestsCannotExceedBudget() throws Exception {
        GeocodingRateLimiter limiter = limiter(3, Duration.ofMinutes(1));
        UUID account = UUID.randomUUID();
        var ready = new CountDownLatch(12);
        var start = new CountDownLatch(1);
        var accepted = new AtomicInteger();
        var denied = new AtomicInteger();
        try (var executor = Executors.newFixedThreadPool(12)) {
            var tasks = new java.util.ArrayList<java.util.concurrent.Future<?>>();
            for (int i = 0; i < 12; i++) {
                tasks.add(executor.submit(() -> {
                    ready.countDown();
                    start.await();
                    try {
                        limiter.check(account);
                        accepted.incrementAndGet();
                    } catch (DomainException ex) {
                        assertThat(ex.getStatus()).isEqualTo(HttpStatus.TOO_MANY_REQUESTS);
                        denied.incrementAndGet();
                    }
                    return null;
                }));
            }
            ready.await();
            start.countDown();
            for (var task : tasks) task.get();
        }
        assertThat(accepted.get()).isEqualTo(3);
        assertThat(denied.get()).isEqualTo(9);
    }

    @Test
    void rejectsInvalidConfiguration() {
        GeocodingProperties properties = new GeocodingProperties();
        properties.setMaxRequests(0);
        assertThatThrownBy(() -> new GeocodingRateLimiter(properties, now::get))
                .isInstanceOf(IllegalArgumentException.class);
        properties.setMaxRequests(30);
        properties.setRateWindow(Duration.ZERO);
        assertThatThrownBy(() -> new GeocodingRateLimiter(properties, now::get))
                .isInstanceOf(IllegalArgumentException.class);
    }

    private GeocodingRateLimiter limiter(int max, Duration window) {
        GeocodingProperties properties = new GeocodingProperties();
        properties.setMaxRequests(max);
        properties.setRateWindow(window);
        return new GeocodingRateLimiter(properties, now::get);
    }

    private void assertRateLimited(Runnable operation) {
        assertThatThrownBy(operation::run).isInstanceOf(DomainException.class)
                .satisfies(error -> {
                    DomainException ex = (DomainException) error;
                    assertThat(ex.getStatus()).isEqualTo(HttpStatus.TOO_MANY_REQUESTS);
                    assertThat(ex.getCode()).isEqualTo("GEOCODING_RATE_LIMITED");
                });
    }
}
