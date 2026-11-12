package com.gomove.pricing.engine;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.math.BigDecimal;
import java.time.DayOfWeek;
import java.time.LocalTime;
import java.util.ArrayList;
import java.util.List;

@ConfigurationProperties(prefix = "gomove.pricing.peak-hour")
public class PeakHourPricingProperties {
    private boolean enabled;
    private String policyVersion;
    private String timezone;
    private BigDecimal multiplier;
    private List<Window> windows = new ArrayList<>();

    public boolean isEnabled() { return enabled; }
    public void setEnabled(boolean enabled) { this.enabled = enabled; }
    public String getPolicyVersion() { return policyVersion; }
    public void setPolicyVersion(String policyVersion) { this.policyVersion = policyVersion; }
    public String getTimezone() { return timezone; }
    public void setTimezone(String timezone) { this.timezone = timezone; }
    public BigDecimal getMultiplier() { return multiplier; }
    public void setMultiplier(BigDecimal multiplier) { this.multiplier = multiplier; }
    public List<Window> getWindows() { return windows; }
    public void setWindows(List<Window> windows) { this.windows = windows; }

    public static class Window {
        private List<DayOfWeek> days = new ArrayList<>();
        private LocalTime start;
        private LocalTime end;
        private String reason;

        public List<DayOfWeek> getDays() { return days; }
        public void setDays(List<DayOfWeek> days) { this.days = days; }
        public LocalTime getStart() { return start; }
        public void setStart(LocalTime start) { this.start = start; }
        public LocalTime getEnd() { return end; }
        public void setEnd(LocalTime end) { this.end = end; }
        public String getReason() { return reason; }
        public void setReason(String reason) { this.reason = reason; }
    }
}
