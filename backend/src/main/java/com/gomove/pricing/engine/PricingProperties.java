package com.gomove.pricing.engine;

import com.gomove.vehicle.domain.VehicleType;
import org.springframework.boot.context.properties.ConfigurationProperties;

import java.math.BigDecimal;
import java.util.EnumMap;
import java.util.Map;

@ConfigurationProperties(prefix = "gomove.pricing")
public class PricingProperties {
    private String engineVersion = "MVP_V1";
    private Map<VehicleType, Tariff> tariffs = new EnumMap<>(VehicleType.class);

    public String getEngineVersion() { return engineVersion; }
    public void setEngineVersion(String engineVersion) { this.engineVersion = engineVersion; }
    public Map<VehicleType, Tariff> getTariffs() { return tariffs; }
    public void setTariffs(Map<VehicleType, Tariff> tariffs) { this.tariffs = tariffs; }

    public static class Tariff {
        private BigDecimal baseFare;
        private BigDecimal pricePerKm;
        private BigDecimal pricePerMinute;
        private BigDecimal surcharge;
        private BigDecimal surgeMultiplier;

        public BigDecimal getBaseFare() { return baseFare; }
        public void setBaseFare(BigDecimal baseFare) { this.baseFare = baseFare; }
        public BigDecimal getPricePerKm() { return pricePerKm; }
        public void setPricePerKm(BigDecimal pricePerKm) { this.pricePerKm = pricePerKm; }
        public BigDecimal getPricePerMinute() { return pricePerMinute; }
        public void setPricePerMinute(BigDecimal pricePerMinute) { this.pricePerMinute = pricePerMinute; }
        public BigDecimal getSurcharge() { return surcharge; }
        public void setSurcharge(BigDecimal surcharge) { this.surcharge = surcharge; }
        public BigDecimal getSurgeMultiplier() { return surgeMultiplier; }
        public void setSurgeMultiplier(BigDecimal surgeMultiplier) { this.surgeMultiplier = surgeMultiplier; }
    }
}
