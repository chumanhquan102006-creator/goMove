package com.gomove.booking.domain;

import com.gomove.auth.domain.User;
import com.gomove.common.persistence.BaseEntity;
import com.gomove.pricing.domain.Quote;
import com.gomove.vehicle.domain.VehicleType;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.OneToOne;
import jakarta.persistence.Table;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;
import org.locationtech.jts.geom.Point;

import java.math.BigDecimal;
import java.util.Map;

@Entity
@Table(name = "bookings")
public class Booking extends BaseEntity {
    @ManyToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "customer_id", nullable = false, updatable = false)
    private User customer;

    @OneToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "quote_id", nullable = false, unique = true, updatable = false)
    private Quote quote;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 24)
    private BookingStatus status;

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

    @Column(name = "final_fare", nullable = false, updatable = false, precision = 15, scale = 2)
    private BigDecimal finalFare;

    @Column(name = "pricing_engine_version", nullable = false, updatable = false, length = 30)
    private String pricingEngineVersion;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "pricing_snapshot", nullable = false, updatable = false, columnDefinition = "jsonb")
    private Map<String, String> pricingSnapshot;

    protected Booking() {
    }

    public Booking(User customer, Quote quote) {
        if (customer == null || quote == null || !customer.getId().equals(quote.getCustomer().getId())) {
            throw new IllegalArgumentException("Booking must belong to the Quote customer");
        }
        this.customer = customer;
        this.quote = quote;
        this.status = BookingStatus.REQUESTED;
        this.pickupLocation = (Point) quote.getPickupLocation().copy();
        this.dropoffLocation = (Point) quote.getDropoffLocation().copy();
        this.distanceMeters = quote.getDistanceMeters();
        this.durationSeconds = quote.getDurationSeconds();
        this.routingProvider = quote.getRoutingProvider();
        this.vehicleType = quote.getVehicleType();
        this.currencyCode = quote.getCurrencyCode();
        this.finalFare = quote.getFinalFare();
        this.pricingEngineVersion = quote.getPricingEngineVersion();
        this.pricingSnapshot = Map.copyOf(quote.getPricingSnapshot());
    }

    public User getCustomer() { return customer; }
    public Quote getQuote() { return quote; }
    public BookingStatus getStatus() { return status; }
    public Point getPickupLocation() { return pickupLocation; }
    public Point getDropoffLocation() { return dropoffLocation; }
    public BigDecimal getDistanceMeters() { return distanceMeters; }
    public BigDecimal getDurationSeconds() { return durationSeconds; }
    public String getRoutingProvider() { return routingProvider; }
    public VehicleType getVehicleType() { return vehicleType; }
    public String getCurrencyCode() { return currencyCode; }
    public BigDecimal getFinalFare() { return finalFare; }
    public String getPricingEngineVersion() { return pricingEngineVersion; }
    public Map<String, String> getPricingSnapshot() { return Map.copyOf(pricingSnapshot); }
}
