package com.gomove.review.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.common.exception.DomainException;
import com.gomove.review.api.*;
import com.gomove.review.infrastructure.ReviewStore;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.Objects;
import java.util.UUID;

@Service
public class RatingService {
    private final ReviewStore store;
    private final int minimumRatings;
    private final int recentWindow;
    private final BigDecimal lowAverageThreshold;

    public RatingService(ReviewStore store,
                         @Value("${gomove.review.quality.minimum-ratings:10}") int minimumRatings,
                         @Value("${gomove.review.quality.recent-window:10}") int recentWindow,
                         @Value("${gomove.review.quality.low-average-threshold:3.0}") BigDecimal lowAverageThreshold) {
        if (minimumRatings < 1 || recentWindow < 1 || recentWindow > 100
                || lowAverageThreshold.compareTo(BigDecimal.ONE) < 0
                || lowAverageThreshold.compareTo(new BigDecimal("5")) > 0) {
            throw new IllegalArgumentException("Invalid quality monitoring policy");
        }
        this.store = store;
        this.minimumRatings = minimumRatings;
        this.recentWindow = recentWindow;
        this.lowAverageThreshold = lowAverageThreshold;
    }

    @Transactional
    public RatingResponse submit(UUID bookingId, UUID customerId, UserRole role, RatingRequest request) {
        requireRole(role, UserRole.CUSTOMER);
        if (request == null || request.stars() < 1 || request.stars() > 5
                || (request.comment() != null && request.comment().length() > 500)) {
            throw new DomainException(HttpStatus.BAD_REQUEST, "INVALID_RATING", "Rating must have 1-5 stars and at most 500 comment characters");
        }
        String comment = request.comment() == null || request.comment().isBlank()
                ? null : request.comment().trim();
        ReviewStore.RatedBooking booking = store.ownedBooking(bookingId, customerId, true)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND, "BOOKING_NOT_FOUND", "Booking not found"));
        if (!"COMPLETED".equals(booking.status()) || booking.driverId() == null) {
            throw new DomainException(HttpStatus.CONFLICT, "RATING_TRIP_NOT_COMPLETED", "Only a completed assigned Booking can be rated");
        }
        var existing = store.rating(booking.id());
        if (existing.isPresent()) {
            RatingResponse prior = existing.get();
            if (prior.stars() == request.stars() && Objects.equals(prior.comment(), comment)) return prior;
            throw new DomainException(HttpStatus.CONFLICT, "RATING_ALREADY_SUBMITTED", "This Booking has already been rated");
        }
        // Serialize ratings for the same Driver so the threshold cannot be
        // missed by simultaneous submissions for different Bookings.
        store.lockDriver(booking.driverId());
        var created = store.insertRating(booking, request.stars(), comment);
        store.insertPoints(created.id(), booking.driverId(), pointsFor(request.stars()));
        ReviewStore.RecentStats stats = store.recentStats(booking.driverId(), recentWindow);
        if (stats.total() >= minimumRatings && stats.average() != null
                && stats.average().compareTo(lowAverageThreshold) < 0) {
            store.flagDriver(booking.driverId(), stats.total(), stats.average(), recentWindow,
                    "Điểm trung bình " + stats.average() + "/5 trong " + recentWindow
                            + " đánh giá gần nhất; tổng " + stats.total() + " đánh giá xác thực.");
        }
        return created.response();
    }

    @Transactional(readOnly = true)
    public RatingLookupResponse ownedRating(UUID bookingId, UUID customerId, UserRole role) {
        requireRole(role, UserRole.CUSTOMER);
        var booking = store.ownedBooking(bookingId, customerId, false)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND, "BOOKING_NOT_FOUND", "Booking not found"));
        var rating = store.rating(booking.id());
        return new RatingLookupResponse(rating.isPresent(), rating.orElse(null));
    }

    @Transactional(readOnly = true)
    public ReputationResponse reputation(UUID driverUserId, UserRole role) {
        long driverId = driverId(driverUserId, role);
        return store.reputation(driverId);
    }

    @Transactional(readOnly = true)
    public ReputationResponse reputationForDriver(long driverId) {
        return store.reputation(driverId);
    }

    @Transactional(readOnly = true)
    public RewardHistoryResponse rewards(UUID driverUserId, UserRole role, int page, int size) {
        if (page < 0 || page > 10_000 || size < 1 || size > 50) {
            throw new DomainException(HttpStatus.BAD_REQUEST, "INVALID_REWARD_PAGE", "Invalid reward page or size");
        }
        return store.rewards(driverId(driverUserId, role), page, size);
    }

    public static int pointsFor(int stars) {
        return switch (stars) {
            case 5 -> 10;
            case 4 -> 5;
            case 3 -> 0;
            case 2 -> -5;
            case 1 -> -10;
            default -> throw new IllegalArgumentException("stars must be between 1 and 5");
        };
    }

    private long driverId(UUID userId, UserRole role) {
        requireRole(role, UserRole.DRIVER);
        return store.driverIdForUser(userId)
                .orElseThrow(() -> new DomainException(HttpStatus.FORBIDDEN, "DRIVER_PROFILE_REQUIRED", "Driver profile is required"));
    }

    private static void requireRole(UserRole actual, UserRole required) {
        if (actual != required) {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Role is not authorized");
        }
    }
}
