package com.gomove.pricing.engine;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.DayOfWeek;
import java.time.Instant;
import java.time.LocalTime;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.util.List;
import org.springframework.stereotype.Component;

/** Evaluates the configured, server-side peak-hour policy for one quote timestamp. */
@Component
public class PeakHourPricingPolicy {
    private static final BigDecimal NO_PEAK_MULTIPLIER = BigDecimal.ONE.setScale(4);

    private final PeakHourPricingProperties properties;
    private final ZoneId zoneId;

    public PeakHourPricingPolicy(PeakHourPricingProperties properties) {
        this.properties = properties;
        validateConfiguration(properties);
        try {
            this.zoneId = ZoneId.of(properties.getTimezone());
        } catch (RuntimeException ex) {
            throw new IllegalArgumentException("Peak pricing timezone must be a valid IANA zone", ex);
        }
    }

    public Evaluation evaluate(Instant timestamp) {
        if (timestamp == null) throw new IllegalArgumentException("Pricing timestamp is required");
        if (!properties.isEnabled()) {
            return new Evaluation(properties.getPolicyVersion(), timestamp, properties.getTimezone(),
                    properties.getMultiplier(), NO_PEAK_MULTIPLIER, false, "FEATURE_DISABLED");
        }

        ZonedDateTime local = timestamp.atZone(zoneId);
        DayOfWeek day = local.getDayOfWeek();
        LocalTime time = local.toLocalTime();
        for (PeakHourPricingProperties.Window window : properties.getWindows()) {
            if (window.getDays().contains(day)
                    && !time.isBefore(window.getStart())
                    && time.isBefore(window.getEnd())) {
                return new Evaluation(properties.getPolicyVersion(), timestamp, properties.getTimezone(),
                        properties.getMultiplier(),
                        properties.getMultiplier().setScale(4, RoundingMode.UNNECESSARY), true,
                        window.getReason());
            }
        }

        String reason = day == DayOfWeek.SATURDAY || day == DayOfWeek.SUNDAY
                ? "NON_PEAK_DAY" : "OUTSIDE_PEAK_HOURS";
        return new Evaluation(properties.getPolicyVersion(), timestamp, properties.getTimezone(),
                properties.getMultiplier(), NO_PEAK_MULTIPLIER, false, reason);
    }

    private void validateConfiguration(PeakHourPricingProperties config) {
        if (config == null || config.getPolicyVersion() == null || config.getPolicyVersion().isBlank()) {
            throw new IllegalArgumentException("Peak pricing policy version is required");
        }
        if (config.getTimezone() == null || config.getTimezone().isBlank()) {
            throw new IllegalArgumentException("Peak pricing timezone is required");
        }
        if (config.getMultiplier() == null || config.getMultiplier().compareTo(BigDecimal.ONE) < 0
                || config.getMultiplier().scale() > 4
                || config.getMultiplier().precision() - config.getMultiplier().scale() > 4) {
            throw new IllegalArgumentException("Peak multiplier must be at least 1.00 and fit NUMERIC(8,4)");
        }
        List<PeakHourPricingProperties.Window> windows = config.getWindows();
        if (windows == null || windows.isEmpty()) {
            throw new IllegalArgumentException("Peak pricing windows are required");
        }
        for (int index = 0; index < windows.size(); index++) {
            PeakHourPricingProperties.Window window = windows.get(index);
            if (window == null || window.getDays() == null || window.getDays().isEmpty()
                    || window.getStart() == null || window.getEnd() == null
                    || !window.getStart().isBefore(window.getEnd())
                    || window.getReason() == null || window.getReason().isBlank()) {
                throw new IllegalArgumentException("Peak pricing windows require days, a valid interval and reason");
            }
            for (int otherIndex = index + 1; otherIndex < windows.size(); otherIndex++) {
                PeakHourPricingProperties.Window other = windows.get(otherIndex);
                if (other != null && overlaps(window, other)) {
                    throw new IllegalArgumentException("Peak pricing windows must not overlap");
                }
            }
        }
        try {
            ZoneId.of(config.getTimezone());
        } catch (RuntimeException ex) {
            throw new IllegalArgumentException("Peak pricing timezone must be a valid IANA zone", ex);
        }
    }

    private boolean overlaps(PeakHourPricingProperties.Window first, PeakHourPricingProperties.Window second) {
        if (second.getDays() == null || second.getStart() == null || second.getEnd() == null) return false;
        boolean sharedDay = first.getDays().stream().anyMatch(second.getDays()::contains);
        return sharedDay && first.getStart().isBefore(second.getEnd())
                && second.getStart().isBefore(first.getEnd());
    }

    public record Evaluation(String policyVersion, Instant timestamp, String timezone,
                             BigDecimal configuredPeakMultiplier, BigDecimal peakMultiplier,
                             boolean applied, String reason) {
        public Evaluation {
            if (policyVersion == null || timestamp == null || timezone == null || configuredPeakMultiplier == null
                    || peakMultiplier == null || reason == null) {
                throw new IllegalArgumentException("Complete peak pricing evaluation is required");
            }
        }
    }
}
