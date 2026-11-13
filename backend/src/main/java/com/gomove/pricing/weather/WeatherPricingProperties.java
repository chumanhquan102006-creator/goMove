package com.gomove.pricing.weather;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.math.BigDecimal;
import java.time.Duration;

@ConfigurationProperties(prefix = "gomove.pricing.weather")
public class WeatherPricingProperties {
    private boolean enabled;
    private String policyVersion = "WEATHER_V1";
    private String provider = "OPEN_METEO";
    private String baseUrl = "https://api.open-meteo.com";
    private Duration connectTimeout = Duration.ofSeconds(2);
    private Duration readTimeout = Duration.ofSeconds(3);
    private Duration maximumAge = Duration.ofMinutes(30);
    private int expectedIntervalSeconds = 900;
    private BigDecimal noRainBelowMm = new BigDecimal("0.2");
    private BigDecimal heavyRainFromMm = new BigDecimal("2.0");
    private BigDecimal rainMultiplier = new BigDecimal("1.10");
    private BigDecimal heavyRainMultiplier = new BigDecimal("1.15");
    private BigDecimal maximumCombinedMultiplier = new BigDecimal("1.50");
    private int cacheCapacity = 256;
    private int cacheGridDecimals = 2;
    private Duration successfulCacheTtl = Duration.ofMinutes(2);
    private Duration failureCacheTtl = Duration.ofSeconds(10);

    public boolean isEnabled() { return enabled; }
    public void setEnabled(boolean enabled) { this.enabled = enabled; }
    public String getPolicyVersion() { return policyVersion; }
    public void setPolicyVersion(String policyVersion) { this.policyVersion = policyVersion; }
    public String getProvider() { return provider; }
    public void setProvider(String provider) { this.provider = provider; }
    public String getBaseUrl() { return baseUrl; }
    public void setBaseUrl(String baseUrl) { this.baseUrl = baseUrl; }
    public Duration getConnectTimeout() { return connectTimeout; }
    public void setConnectTimeout(Duration connectTimeout) { this.connectTimeout = connectTimeout; }
    public Duration getReadTimeout() { return readTimeout; }
    public void setReadTimeout(Duration readTimeout) { this.readTimeout = readTimeout; }
    public Duration getMaximumAge() { return maximumAge; }
    public void setMaximumAge(Duration maximumAge) { this.maximumAge = maximumAge; }
    public int getExpectedIntervalSeconds() { return expectedIntervalSeconds; }
    public void setExpectedIntervalSeconds(int expectedIntervalSeconds) { this.expectedIntervalSeconds = expectedIntervalSeconds; }
    public BigDecimal getNoRainBelowMm() { return noRainBelowMm; }
    public void setNoRainBelowMm(BigDecimal noRainBelowMm) { this.noRainBelowMm = noRainBelowMm; }
    public BigDecimal getHeavyRainFromMm() { return heavyRainFromMm; }
    public void setHeavyRainFromMm(BigDecimal heavyRainFromMm) { this.heavyRainFromMm = heavyRainFromMm; }
    public BigDecimal getRainMultiplier() { return rainMultiplier; }
    public void setRainMultiplier(BigDecimal rainMultiplier) { this.rainMultiplier = rainMultiplier; }
    public BigDecimal getHeavyRainMultiplier() { return heavyRainMultiplier; }
    public void setHeavyRainMultiplier(BigDecimal heavyRainMultiplier) { this.heavyRainMultiplier = heavyRainMultiplier; }
    public BigDecimal getMaximumCombinedMultiplier() { return maximumCombinedMultiplier; }
    public void setMaximumCombinedMultiplier(BigDecimal maximumCombinedMultiplier) { this.maximumCombinedMultiplier = maximumCombinedMultiplier; }
    public int getCacheCapacity() { return cacheCapacity; }
    public void setCacheCapacity(int cacheCapacity) { this.cacheCapacity = cacheCapacity; }
    public int getCacheGridDecimals() { return cacheGridDecimals; }
    public void setCacheGridDecimals(int cacheGridDecimals) { this.cacheGridDecimals = cacheGridDecimals; }
    public Duration getSuccessfulCacheTtl() { return successfulCacheTtl; }
    public void setSuccessfulCacheTtl(Duration successfulCacheTtl) { this.successfulCacheTtl = successfulCacheTtl; }
    public Duration getFailureCacheTtl() { return failureCacheTtl; }
    public void setFailureCacheTtl(Duration failureCacheTtl) { this.failureCacheTtl = failureCacheTtl; }
}
