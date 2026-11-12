package com.gomove.pricing.engine;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.DayOfWeek;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.List;
import java.util.TimeZone;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class PeakHourPricingPolicyTest {
    private static final ZoneId HANOI = ZoneId.of("Asia/Ho_Chi_Minh");

    @Test
    void appliesWeekdayWindowsWithInclusiveStartAndExclusiveEnd() {
        PeakHourPricingPolicy policy = policy(true);

        assertApplied(policy, Instant.parse("2026-10-05T00:00:00Z"), "WEEKDAY_MORNING_PEAK");
        assertApplied(policy, Instant.parse("2026-10-05T01:59:59Z"), "WEEKDAY_MORNING_PEAK");
        assertNotApplied(policy, Instant.parse("2026-10-05T02:00:00Z"), "OUTSIDE_PEAK_HOURS");
        assertNotApplied(policy, Instant.parse("2026-10-05T09:59:59Z"), "OUTSIDE_PEAK_HOURS");
        assertApplied(policy, Instant.parse("2026-10-05T10:00:00Z"), "WEEKDAY_EVENING_PEAK");
        assertApplied(policy, Instant.parse("2026-10-05T11:59:59Z"), "WEEKDAY_EVENING_PEAK");
        assertNotApplied(policy, Instant.parse("2026-10-05T12:00:00Z"), "OUTSIDE_PEAK_HOURS");
    }

    @Test
    void appliesEveryWeekdayAndNeverAppliesOnWeekends() {
        PeakHourPricingPolicy policy = policy(true);
        for (int dayOffset = 0; dayOffset < 5; dayOffset++) {
            Instant morning = LocalDate.of(2026, 10, 5).plusDays(dayOffset)
                    .atTime(7, 0).atZone(HANOI).toInstant();
            assertThat(policy.evaluate(morning).applied()).isTrue();
        }

        for (int dayOffset = 5; dayOffset < 7; dayOffset++) {
            Instant weekendMorning = LocalDate.of(2026, 10, 5).plusDays(dayOffset)
                    .atTime(8, 0).atZone(HANOI).toInstant();
            assertNotApplied(policy, weekendMorning, "NON_PEAK_DAY");
        }
    }

    @Test
    void usesExplicitHanoiZoneIndependentOfHostDefaultTimezone() {
        PeakHourPricingPolicy policy = policy(true);
        Instant utcStart = Instant.parse("2026-10-05T00:00:00Z");
        TimeZone original = TimeZone.getDefault();
        try {
            TimeZone.setDefault(TimeZone.getTimeZone("Pacific/Honolulu"));
            PeakHourPricingPolicy.Evaluation first = policy.evaluate(utcStart);
            TimeZone.setDefault(TimeZone.getTimeZone("UTC"));
            PeakHourPricingPolicy.Evaluation second = policy.evaluate(utcStart);

            assertThat(first).isEqualTo(second);
            assertThat(first.timestamp()).isEqualTo(utcStart);
            assertThat(first.applied()).isTrue();
        } finally {
            TimeZone.setDefault(original);
        }
    }

    @Test
    void disabledFeatureDoesNotApplyPeakMultiplier() {
        PeakHourPricingPolicy.Evaluation evaluation = policy(false)
                .evaluate(Instant.parse("2026-10-05T00:30:00Z"));

        assertThat(evaluation.applied()).isFalse();
        assertThat(evaluation.peakMultiplier()).isEqualTo(new BigDecimal("1.0000"));
        assertThat(evaluation.reason()).isEqualTo("FEATURE_DISABLED");
    }

    @Test
    void invalidPolicyConfigurationIsRejected() {
        for (String invalidValue : List.of("0.80", "0", "-0.01", "1.00001", "10000.0000")) {
            PeakHourPricingProperties invalidMultiplier = properties(true);
            invalidMultiplier.setMultiplier(new BigDecimal(invalidValue));
            assertThatThrownBy(() -> new PeakHourPricingPolicy(invalidMultiplier))
                    .as("multiplier %s", invalidValue)
                    .isInstanceOf(IllegalArgumentException.class)
                    .hasMessageContaining("NUMERIC(8,4)");
        }

        PeakHourPricingProperties invalidTimezone = properties(true);
        invalidTimezone.setTimezone("Not/A_Timezone");
        assertThatThrownBy(() -> new PeakHourPricingPolicy(invalidTimezone))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("timezone");

        PeakHourPricingProperties overlapping = properties(true);
        PeakHourPricingProperties.Window overlap = window(List.of(DayOfWeek.MONDAY), "08:00", "10:00", "OVERLAP");
        overlapping.getWindows().add(overlap);
        assertThatThrownBy(() -> new PeakHourPricingPolicy(overlapping))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("overlap");
    }

    private void assertApplied(PeakHourPricingPolicy policy, Instant at, String reason) {
        PeakHourPricingPolicy.Evaluation result = policy.evaluate(at);
        assertThat(result.applied()).isTrue();
        assertThat(result.peakMultiplier()).isEqualTo(new BigDecimal("1.2000"));
        assertThat(result.reason()).isEqualTo(reason);
    }

    private void assertNotApplied(PeakHourPricingPolicy policy, Instant at, String reason) {
        PeakHourPricingPolicy.Evaluation result = policy.evaluate(at);
        assertThat(result.applied()).isFalse();
        assertThat(result.peakMultiplier()).isEqualTo(new BigDecimal("1.0000"));
        assertThat(result.reason()).isEqualTo(reason);
    }

    private PeakHourPricingPolicy policy(boolean enabled) {
        return new PeakHourPricingPolicy(properties(enabled));
    }

    private PeakHourPricingProperties properties(boolean enabled) {
        PeakHourPricingProperties properties = new PeakHourPricingProperties();
        properties.setEnabled(enabled);
        properties.setPolicyVersion("PEAK_HOUR_V1");
        properties.setTimezone("Asia/Ho_Chi_Minh");
        properties.setMultiplier(new BigDecimal("1.20"));
        List<PeakHourPricingProperties.Window> windows = new ArrayList<>();
        List<DayOfWeek> weekdays = List.of(DayOfWeek.MONDAY, DayOfWeek.TUESDAY, DayOfWeek.WEDNESDAY,
                DayOfWeek.THURSDAY, DayOfWeek.FRIDAY);
        windows.add(window(weekdays, "07:00", "09:00", "WEEKDAY_MORNING_PEAK"));
        windows.add(window(weekdays, "17:00", "19:00", "WEEKDAY_EVENING_PEAK"));
        properties.setWindows(windows);
        return properties;
    }

    private PeakHourPricingProperties.Window window(List<DayOfWeek> days, String start, String end, String reason) {
        PeakHourPricingProperties.Window window = new PeakHourPricingProperties.Window();
        window.setDays(days);
        window.setStart(LocalTime.parse(start));
        window.setEnd(LocalTime.parse(end));
        window.setReason(reason);
        return window;
    }
}
