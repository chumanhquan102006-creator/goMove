package com.gomove.driver.domain;

import com.gomove.auth.domain.User;
import com.gomove.common.persistence.BaseEntity;
import jakarta.persistence.*;

import java.math.BigDecimal;

@Entity
@Table(name = "drivers")
public class Driver extends BaseEntity {
    @OneToOne(fetch = FetchType.LAZY, optional = false)
    @JoinColumn(name = "user_id", nullable = false, unique = true)
    private User user;

    @Column(name = "license_number", nullable = false, unique = true, length = 50)
    private String licenseNumber;

    @Enumerated(EnumType.STRING)
    @Column(name = "approval_status", nullable = false, length = 20)
    private DriverApprovalStatus approvalStatus = DriverApprovalStatus.PENDING;

    @Enumerated(EnumType.STRING)
    @Column(name = "operating_status", nullable = false, length = 20)
    private DriverOperatingStatus operatingStatus = DriverOperatingStatus.OFFLINE;

    @Column(name = "rating_average", nullable = false, precision = 3, scale = 2)
    private BigDecimal ratingAverage = new BigDecimal("5.00");

    @Column(name = "total_trips", nullable = false)
    private int totalTrips = 0;

    protected Driver() {
    }

    public Driver(User user, String licenseNumber) {
        this.user = user;
        this.licenseNumber = licenseNumber;
    }

    public User getUser() {
        return user;
    }

    public String getLicenseNumber() {
        return licenseNumber;
    }

    public DriverApprovalStatus getApprovalStatus() {
        return approvalStatus;
    }

    public DriverOperatingStatus getOperatingStatus() {
        return operatingStatus;
    }

    public BigDecimal getRatingAverage() {
        return ratingAverage;
    }

    public int getTotalTrips() {
        return totalTrips;
    }

    public void setApprovalStatus(DriverApprovalStatus approvalStatus) {
        this.approvalStatus = approvalStatus;
    }

    public void setOperatingStatus(DriverOperatingStatus operatingStatus) {
        this.operatingStatus = operatingStatus;
    }
}
