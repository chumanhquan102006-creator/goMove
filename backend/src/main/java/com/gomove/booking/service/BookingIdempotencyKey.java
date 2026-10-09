package com.gomove.booking.service;

import com.gomove.common.exception.DomainException;
import org.springframework.http.HttpStatus;

import java.util.regex.Pattern;

public final class BookingIdempotencyKey {
    // 8-128 safe ASCII characters; UUID strings are valid.
    private static final Pattern FORMAT = Pattern.compile("[A-Za-z0-9][A-Za-z0-9._:-]{7,127}");

    private BookingIdempotencyKey() {
    }

    public static String requireValid(String key) {
        if (key == null || !FORMAT.matcher(key).matches()) {
            throw new DomainException(HttpStatus.BAD_REQUEST, "INVALID_IDEMPOTENCY_KEY",
                    "Idempotency-Key must be 8-128 safe ASCII characters");
        }
        return key;
    }
}
