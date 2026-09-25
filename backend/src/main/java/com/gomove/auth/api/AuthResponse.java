package com.gomove.auth.api;
public record AuthResponse(String accessToken, String refreshToken, String tokenType, long expiresIn, UserResponse user) { }
