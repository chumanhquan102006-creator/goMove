package com.gomove.common.api;
import java.time.Instant;
import java.util.Map;
public record ErrorResponse(boolean success, String code, String message, String path, Map<String, String> details, Instant timestamp) {
    public static ErrorResponse of(String code, String message, String path, Map<String, String> details) { return new ErrorResponse(false, code, message, path, details, Instant.now()); }
}
