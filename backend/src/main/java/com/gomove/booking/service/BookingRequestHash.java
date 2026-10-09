package com.gomove.booking.service;

import org.springframework.stereotype.Component;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.UUID;

@Component
public class BookingRequestHash {
    private static final String OPERATION = "booking.create.v1";

    public String calculate(UUID customerPublicId, UUID quotePublicId) {
        if (customerPublicId == null || quotePublicId == null) {
            throw new IllegalArgumentException("Customer and Quote UUIDs are required");
        }
        try {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            DataOutputStream canonical = new DataOutputStream(bytes);
            // Each UTF-8 field has a four-byte big-endian length, then its bytes.
            field(canonical, OPERATION);
            field(canonical, customerPublicId.toString());
            field(canonical, quotePublicId.toString());
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray()));
        } catch (IOException | NoSuchAlgorithmException ex) {
            throw new IllegalStateException("Cannot hash booking request", ex);
        }
    }

    private void field(DataOutputStream out, String value) throws IOException {
        byte[] utf8 = value.getBytes(StandardCharsets.UTF_8);
        out.writeInt(utf8.length);
        out.write(utf8);
    }
}
