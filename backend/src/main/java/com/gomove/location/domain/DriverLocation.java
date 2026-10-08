package com.gomove.location.domain;

import com.gomove.driver.domain.Driver;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.OneToOne;
import jakarta.persistence.Table;
import jakarta.persistence.Version;
import org.locationtech.jts.geom.Point;

import java.time.Instant;

@Entity
@Table(name = "driver_locations")
public class DriverLocation {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @OneToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "driver_id", nullable = false, unique = true)
    private Driver driver;

    @Column(name = "current_location", nullable = false, columnDefinition = "geography(Point,4326)")
    private Point currentLocation;

    private Double accuracy;

    private Double bearing;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @Version
    @Column(nullable = false)
    private Long version;

    protected DriverLocation() {
    }

    public Long getId() {
        return id;
    }

    public Driver getDriver() {
        return driver;
    }

    public Point getCurrentLocation() {
        return currentLocation;
    }

    public Double getAccuracy() {
        return accuracy;
    }

    public Double getBearing() {
        return bearing;
    }

    public Instant getUpdatedAt() {
        return updatedAt;
    }

    public Long getVersion() {
        return version;
    }
}
