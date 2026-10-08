package com.gomove.location.infrastructure;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "gomove.location")
public class LocationProperties {
    private long dispatchFreshnessSeconds = 30;

    public long getDispatchFreshnessSeconds() {
        return dispatchFreshnessSeconds;
    }

    public void setDispatchFreshnessSeconds(long dispatchFreshnessSeconds) {
        this.dispatchFreshnessSeconds = dispatchFreshnessSeconds;
    }
}
