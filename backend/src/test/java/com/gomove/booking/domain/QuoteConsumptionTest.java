package com.gomove.booking.domain;

import com.gomove.auth.domain.User;
import com.gomove.common.exception.DomainException;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.Quote;
import com.gomove.pricing.domain.QuoteStatus;
import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.engine.PricingEngine;
import com.gomove.pricing.engine.PricingEngineTest;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class QuoteConsumptionTest {
    private static final Instant ISSUED = Instant.parse("2026-10-08T01:00:00Z");

    @Test
    void justBeforeExpiryConsumesOnceWithoutChangingCommercialSnapshot() {
        Quote quote = quote();
        var originalSnapshot = quote.getPricingSnapshot();
        BigDecimal originalFare = quote.getFinalFare();
        Instant beforeExpiry = ISSUED.plusSeconds(60).minusNanos(1);

        quote.consume(beforeExpiry);

        assertThat(quote.getStatus()).isEqualTo(QuoteStatus.CONSUMED);
        assertThat(quote.getConsumedAt()).isEqualTo(beforeExpiry);
        assertThat(quote.getFinalFare()).isEqualTo(originalFare);
        assertThat(quote.getPricingSnapshot()).isEqualTo(originalSnapshot);
        assertThatThrownBy(() -> quote.consume(beforeExpiry))
                .isInstanceOf(DomainException.class)
                .extracting(ex -> ((DomainException) ex).getCode()).isEqualTo("QUOTE_ALREADY_CONSUMED");
        assertThat(quote.getConsumedAt()).isEqualTo(beforeExpiry);
    }

    @Test
    void exactExpiryAndLaterAreRejectedWithoutMutation() {
        for (Instant attempt : new Instant[]{ISSUED.plusSeconds(60), ISSUED.plusSeconds(61)}) {
            Quote quote = quote();
            assertThatThrownBy(() -> quote.consume(attempt))
                    .isInstanceOf(DomainException.class)
                    .extracting(ex -> ((DomainException) ex).getCode()).isEqualTo("QUOTE_EXPIRED");
            assertThat(quote.getStatus()).isEqualTo(QuoteStatus.ISSUED);
            assertThat(quote.getConsumedAt()).isNull();
        }
    }

    private Quote quote() {
        RouteEstimate route = new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "TEST");
        return new Quote(new User("0900000001", null, "hash", "Customer"),
                new GeoCoordinate(new BigDecimal("21.0287"), new BigDecimal("105.8524")),
                new GeoCoordinate(new BigDecimal("21.0245"), new BigDecimal("105.8576")),
                VehicleType.MOTORBIKE, route,
                new PricingEngine(PricingEngineTest.properties()).calculate(VehicleType.MOTORBIKE, route), ISSUED);
    }
}
