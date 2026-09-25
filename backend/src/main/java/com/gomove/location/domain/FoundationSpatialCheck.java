package com.gomove.location.domain;
import com.gomove.common.persistence.BaseEntity;
import jakarta.persistence.*;
import org.locationtech.jts.geom.Point;
@Entity @Table(name = "foundation_spatial_check")
public class FoundationSpatialCheck extends BaseEntity {
    @Column(nullable=false, length=100) private String name;
    @Column(nullable=false, columnDefinition="geography(Point,4326)") private Point location;
    protected FoundationSpatialCheck() { }
    public FoundationSpatialCheck(String name, Point location) { this.name=name; this.location=location; }
    public String getName() { return name; } public Point getLocation() { return location; }
}
