package com.gomove.dispatch.service;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

@Validated
@ConfigurationProperties(prefix = "gomove.dispatch")
public class DispatchProperties {
    @DecimalMin("1.0")
    private double radiusMeters = 5000;
    @Min(1) @Max(100)
    private int batchSize = 25;
    @Min(1)
    private long retrySeconds = 5;

    public double getRadiusMeters() { return radiusMeters; }
    public void setRadiusMeters(double radiusMeters) { this.radiusMeters = radiusMeters; }
    public int getBatchSize() { return batchSize; }
    public void setBatchSize(int batchSize) { this.batchSize = batchSize; }
    public long getRetrySeconds() { return retrySeconds; }
    public void setRetrySeconds(long retrySeconds) { this.retrySeconds = retrySeconds; }
}
