package com.gomove.pricing.domain;

import com.gomove.auth.domain.User;
import com.gomove.pricing.engine.PricingEngine;
import com.gomove.pricing.engine.PricingEngineTest;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;

class QuoteLifecycleTest {
    @Test
    void issuedQuoteExpiresExactlyAtSixtySecondsAndKeepsSnapshot() {
        Instant issuedAt = Instant.parse("2026-10-08T01:00:00Z");
        Quote quote = quote(issuedAt);
        var originalSnapshot = quote.getPricingSnapshot();

        assertThat(quote.getStatus()).isEqualTo(QuoteStatus.ISSUED);
        assertThat(quote.getExpiresAt()).isEqualTo(issuedAt.plusSeconds(60));
        assertThat(quote.isUsableAt(issuedAt.plusSeconds(60).minusNanos(1))).isTrue();
        assertThat(quote.isUsableAt(issuedAt.plusSeconds(60))).isFalse();
        assertThat(quote.effectiveStatus(issuedAt.plusSeconds(60))).isEqualTo(QuoteStatus.EXPIRED);
        assertThat(quote.effectiveStatus(issuedAt.plusSeconds(61))).isEqualTo(QuoteStatus.EXPIRED);
        assertThat(quote.getStatus()).isEqualTo(QuoteStatus.ISSUED);
        assertThat(quote.getPricingEngineVersion()).isEqualTo("MVP_V1");
        assertThat(quote.getPricingSnapshot()).isEqualTo(originalSnapshot);
        assertThat(quote.getConsumedAt()).isNull();
        assertThat(QuoteStatus.values()).contains(QuoteStatus.CONSUMED);
    }

    private Quote quote(Instant issuedAt) {
        return new Quote(
                new User("0900000001", null, "hash", "Customer"),
                new GeoCoordinate(new BigDecimal("21.0287"), new BigDecimal("105.8524")),
                new GeoCoordinate(new BigDecimal("21.0245"), new BigDecimal("105.8576")),
                VehicleType.MOTORBIKE,
                new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "TEST"),
                new PricingEngine(PricingEngineTest.properties()).calculate(VehicleType.MOTORBIKE,
                        new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "TEST")),
                issuedAt);
    }
}
