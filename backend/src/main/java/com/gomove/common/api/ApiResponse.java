package com.gomove.common.api;
import java.time.Instant;
public record ApiResponse<T>(boolean success, String code, String message, T data, Instant timestamp) {
    public static <T> ApiResponse<T> success(String code, String message, T data) { return new ApiResponse<>(true, code, message, data, Instant.now()); }
}
