package com.gomove.pricing.demandsupply;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.math.BigDecimal;
import java.time.Duration;

@ConfigurationProperties(prefix = "gomove.pricing.demand-supply")
public class DemandSupplyPricingProperties {
    private boolean enabled;
    private String policyVersion = "DEMAND_SUPPLY_V1";
    private int radiusMeters = 5_000;
    private Duration lookback = Duration.ofMinutes(5);
    private long driverLocationFreshnessSeconds = 30;
    private int minimumDemand = 3;
    private BigDecimal lowRatioThreshold = new BigDecimal("2.0");
    private BigDecimal highRatioThreshold = new BigDecimal("4.0");
    private BigDecimal moderateMultiplier = new BigDecimal("1.1000");
    private BigDecimal highMultiplier = new BigDecimal("1.2000");
    private BigDecimal maximumMultiplier = new BigDecimal("1.2000");

    public boolean isEnabled() { return enabled; }
    public void setEnabled(boolean enabled) { this.enabled = enabled; }
    public String getPolicyVersion() { return policyVersion; }
    public void setPolicyVersion(String policyVersion) { this.policyVersion = policyVersion; }
    public int getRadiusMeters() { return radiusMeters; }
    public void setRadiusMeters(int radiusMeters) { this.radiusMeters = radiusMeters; }
    public Duration getLookback() { return lookback; }
    public void setLookback(Duration lookback) { this.lookback = lookback; }
    public long getDriverLocationFreshnessSeconds() { return driverLocationFreshnessSeconds; }
    public void setDriverLocationFreshnessSeconds(long value) { this.driverLocationFreshnessSeconds = value; }
    public int getMinimumDemand() { return minimumDemand; }
    public void setMinimumDemand(int minimumDemand) { this.minimumDemand = minimumDemand; }
    public BigDecimal getLowRatioThreshold() { return lowRatioThreshold; }
    public void setLowRatioThreshold(BigDecimal lowRatioThreshold) { this.lowRatioThreshold = lowRatioThreshold; }
    public BigDecimal getHighRatioThreshold() { return highRatioThreshold; }
    public void setHighRatioThreshold(BigDecimal highRatioThreshold) { this.highRatioThreshold = highRatioThreshold; }
    public BigDecimal getModerateMultiplier() { return moderateMultiplier; }
    public void setModerateMultiplier(BigDecimal moderateMultiplier) { this.moderateMultiplier = moderateMultiplier; }
    public BigDecimal getHighMultiplier() { return highMultiplier; }
    public void setHighMultiplier(BigDecimal highMultiplier) { this.highMultiplier = highMultiplier; }
    public BigDecimal getMaximumMultiplier() { return maximumMultiplier; }
    public void setMaximumMultiplier(BigDecimal maximumMultiplier) { this.maximumMultiplier = maximumMultiplier; }
}
