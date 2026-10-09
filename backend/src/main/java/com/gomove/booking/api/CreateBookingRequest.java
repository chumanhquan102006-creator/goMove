package com.gomove.booking.api;

import com.fasterxml.jackson.annotation.JsonAnySetter;
import io.swagger.v3.oas.annotations.media.Schema;
import jakarta.validation.constraints.NotNull;

import java.util.UUID;

@Schema(description = "Book an owned, unexpired Quote. Identity and fare come from the JWT and persisted Quote.")
public class CreateBookingRequest {
    @NotNull
    @Schema(requiredMode = Schema.RequiredMode.REQUIRED,
            example = "550e8400-e29b-41d4-a716-446655440000")
    private UUID quotePublicId;

    @JsonAnySetter
    void rejectUnexpectedField(String field, Object value) {
        throw new IllegalArgumentException("Unexpected booking request field: " + field);
    }

    public UUID getQuotePublicId() { return quotePublicId; }
    public void setQuotePublicId(UUID quotePublicId) { this.quotePublicId = quotePublicId; }
}
