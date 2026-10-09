package com.gomove.pricing.domain;

import com.gomove.auth.domain.User;
import com.gomove.common.exception.DomainException;
import com.gomove.common.persistence.BaseEntity;
import com.gomove.pricing.engine.FareBreakdown;
import com.gomove.vehicle.domain.VehicleType;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;
import org.springframework.http.HttpStatus;
import org.locationtech.jts.geom.Coordinate;
import org.locationtech.jts.geom.GeometryFactory;
import org.locationtech.jts.geom.Point;
import org.locationtech.jts.geom.PrecisionModel;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.Map;

@Entity
@Table(name = "quotes")
public class Quote extends BaseEntity {
    private static final GeometryFactory GEOMETRY = new GeometryFactory(new PrecisionModel(), 4326);

    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "customer_id", nullable = false, updatable = false)
    private User customer;

    @Column(name = "pickup_location", nullable = false, updatable = false, columnDefinition = "geography(Point,4326)")
    private Point pickupLocation;

    @Column(name = "dropoff_location", nullable = false, updatable = false, columnDefinition = "geography(Point,4326)")
    private Point dropoffLocation;

    @Column(name = "distance_meters", nullable = false, updatable = false, precision = 15, scale = 3)
    private BigDecimal distanceMeters;

    @Column(name = "duration_seconds", nullable = false, updatable = false, precision = 15, scale = 3)
    private BigDecimal durationSeconds;

    @Column(name = "routing_provider", nullable = false, updatable = false, length = 40)
    private String routingProvider;

    @Enumerated(EnumType.STRING)
    @Column(name = "vehicle_type", nullable = false, updatable = false, length = 20)
    private VehicleType vehicleType;

    @Column(name = "currency_code", nullable = false, updatable = false, length = 3)
    private String currencyCode;

    @Column(name = "base_fare", nullable = false, updatable = false, precision = 15, scale = 2)
    private BigDecimal baseFare;

    @Column(name = "distance_fare", nullable = false, updatable = false, precision = 15, scale = 2)
    private BigDecimal distanceFare;

    @Column(name = "time_fare", nullable = false, updatable = false, precision = 15, scale = 2)
    private BigDecimal timeFare;

    @Column(name = "surcharge", nullable = false, updatable = false, precision = 15, scale = 2)
    private BigDecimal surcharge;

    @Column(name = "surge_multiplier", nullable = false, updatable = false, precision = 8, scale = 4)
    private BigDecimal surgeMultiplier;

    @Column(name = "surge_amount", nullable = false, updatable = false, precision = 15, scale = 2)
    private BigDecimal surgeAmount;

    @Column(name = "discount_amount", nullable = false, updatable = false, precision = 15, scale = 2)
    private BigDecimal discountAmount;

    @Column(name = "rounding_adjustment", nullable = false, updatable = false, precision = 15, scale = 2)
    private BigDecimal roundingAdjustment;

    @Column(name = "final_fare", nullable = false, updatable = false, precision = 15, scale = 2)
    private BigDecimal finalFare;

    @Column(name = "pricing_engine_version", nullable = false, updatable = false, length = 30)
    private String pricingEngineVersion;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "pricing_snapshot", nullable = false, updatable = false, columnDefinition = "jsonb")
    private Map<String, String> pricingSnapshot;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private QuoteStatus status;

    @Column(name = "issued_at", nullable = false, updatable = false)
    private Instant issuedAt;

    @Column(name = "expires_at", nullable = false, updatable = false)
    private Instant expiresAt;

    @Column(name = "consumed_at")
    private Instant consumedAt;

    protected Quote() {
    }

    public Quote(User customer, GeoCoordinate pickup, GeoCoordinate dropoff,
                 VehicleType vehicleType, RouteEstimate route, FareBreakdown fare, Instant issuedAt) {
        if (customer == null || pickup == null || dropoff == null || vehicleType == null
                || route == null || fare == null || issuedAt == null) {
            throw new IllegalArgumentException("Complete quote inputs are required");
        }
        this.customer = customer;
        this.pickupLocation = point(pickup);
        this.dropoffLocation = point(dropoff);
        this.distanceMeters = route.distanceMeters();
        this.durationSeconds = route.durationSeconds();
        this.routingProvider = route.provider();
        this.vehicleType = vehicleType;
        this.currencyCode = fare.currency();
        this.baseFare = fare.baseFare();
        this.distanceFare = fare.distanceFare();
        this.timeFare = fare.timeFare();
        this.surcharge = fare.surcharge();
        this.surgeMultiplier = fare.surgeMultiplier();
        this.surgeAmount = fare.surgeAmount();
        this.discountAmount = fare.discountAmount();
        this.roundingAdjustment = fare.roundingAdjustment();
        this.finalFare = fare.finalFare();
        this.pricingEngineVersion = fare.pricingEngineVersion();
        this.pricingSnapshot = Map.copyOf(fare.snapshot());
        this.status = QuoteStatus.ISSUED;
        this.issuedAt = issuedAt;
        this.expiresAt = issuedAt.plusSeconds(60);
    }

    private static Point point(GeoCoordinate coordinate) {
        Point point = GEOMETRY.createPoint(new Coordinate(
                coordinate.longitude().doubleValue(), coordinate.latitude().doubleValue()));
        point.setSRID(4326);
        return point;
    }

    public QuoteStatus effectiveStatus(Instant now) {
        if (status == QuoteStatus.ISSUED && !now.isBefore(expiresAt)) return QuoteStatus.EXPIRED;
        return status;
    }

    public boolean isUsableAt(Instant now) {
        return status == QuoteStatus.ISSUED && now.isBefore(expiresAt);
    }

    public void consume(Instant now) {
        if (now == null) throw new IllegalArgumentException("Consumption time is required");
        if (status == QuoteStatus.CONSUMED) {
            throw new DomainException(HttpStatus.CONFLICT, "QUOTE_ALREADY_CONSUMED", "Quote has already been consumed");
        }
        if (status != QuoteStatus.ISSUED || !now.isBefore(expiresAt)) {
            throw new DomainException(HttpStatus.CONFLICT, "QUOTE_EXPIRED", "Quote has expired");
        }
        status = QuoteStatus.CONSUMED;
        consumedAt = now;
    }

    public User getCustomer() { return customer; }
    public Point getPickupLocation() { return pickupLocation; }
    public Point getDropoffLocation() { return dropoffLocation; }
    public BigDecimal getDistanceMeters() { return distanceMeters; }
    public BigDecimal getDurationSeconds() { return durationSeconds; }
    public String getRoutingProvider() { return routingProvider; }
    public VehicleType getVehicleType() { return vehicleType; }
    public String getCurrencyCode() { return currencyCode; }
    public BigDecimal getBaseFare() { return baseFare; }
    public BigDecimal getDistanceFare() { return distanceFare; }
    public BigDecimal getTimeFare() { return timeFare; }
    public BigDecimal getSurcharge() { return surcharge; }
    public BigDecimal getSurgeMultiplier() { return surgeMultiplier; }
    public BigDecimal getSurgeAmount() { return surgeAmount; }
    public BigDecimal getDiscountAmount() { return discountAmount; }
    public BigDecimal getRoundingAdjustment() { return roundingAdjustment; }
    public BigDecimal getFinalFare() { return finalFare; }
    public String getPricingEngineVersion() { return pricingEngineVersion; }
    public Map<String, String> getPricingSnapshot() { return Map.copyOf(pricingSnapshot); }
    public QuoteStatus getStatus() { return status; }
    public Instant getIssuedAt() { return issuedAt; }
    public Instant getExpiresAt() { return expiresAt; }
    public Instant getConsumedAt() { return consumedAt; }
}
