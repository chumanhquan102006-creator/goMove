package com.gomove.booking.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.booking.api.CreateBookingRequest;
import com.gomove.common.exception.DomainException;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class BookingRequestHashTest {
    private final BookingRequestHash hashes = new BookingRequestHash();
    private final UUID customer = UUID.fromString("d5932be1-5b83-4afa-9033-a37fa3918679");
    private final UUID quote = UUID.fromString("550e8400-e29b-41d4-a716-446655440000");

    @Test
    void semanticRequestHashIsDeterministicAcrossJsonWhitespace() throws Exception {
        ObjectMapper mapper = new ObjectMapper();
        CreateBookingRequest compact = mapper.readValue(
                "{\"quotePublicId\":\"550e8400-e29b-41d4-a716-446655440000\"}", CreateBookingRequest.class);
        CreateBookingRequest spaced = mapper.readValue(
                "{ \n  \"quotePublicId\" : \"550e8400-e29b-41d4-a716-446655440000\" \n}", CreateBookingRequest.class);

        String first = hashes.calculate(customer, compact.getQuotePublicId());
        assertThat(first).hasSize(64).matches("[0-9a-f]{64}");
        assertThat(hashes.calculate(customer, spaced.getQuotePublicId())).isEqualTo(first);
        assertThat(hashes.calculate(customer, quote)).isEqualTo(first);
        assertThat(hashes.calculate(customer, UUID.randomUUID())).isNotEqualTo(first);
        assertThat(hashes.calculate(UUID.randomUUID(), quote)).isNotEqualTo(first);
    }

    @Test
    void keyFormatIsBoundedAndAcceptsUuid() {
        assertThat(BookingIdempotencyKey.requireValid(UUID.randomUUID().toString())).hasSize(36);
        assertThat(BookingIdempotencyKey.requireValid("A1234567._:-")).isEqualTo("A1234567._:-");
        for (String invalid : new String[]{"", " ", "short", "a key with spaces", "é2345678", "a".repeat(129)}) {
            assertThatThrownBy(() -> BookingIdempotencyKey.requireValid(invalid))
                    .isInstanceOf(DomainException.class).hasMessageContaining("Idempotency-Key");
        }
        assertThatThrownBy(() -> BookingIdempotencyKey.requireValid(null))
                .isInstanceOf(DomainException.class);
    }

    @Test
    void storedOutcomeReplaysOnlyMatchingHashAndOriginalBody() {
        String original = "{\"success\":true,\"timestamp\":\"2026-10-08T01:00:00Z\"}";
        BookingIdempotencyStore.StoredOutcome saved = new BookingIdempotencyStore.StoredOutcome("hash", 201, original);
        assertThat(saved.replay("hash")).isEqualTo(new BookingResult(201, original));
        assertThatThrownBy(() -> saved.replay("different"))
                .isInstanceOf(DomainException.class)
                .extracting(ex -> ((DomainException) ex).getCode()).isEqualTo("IDEMPOTENCY_KEY_REUSED");
    }
}
