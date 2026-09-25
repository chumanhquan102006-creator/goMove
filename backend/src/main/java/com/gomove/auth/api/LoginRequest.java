package com.gomove.auth.api;
import jakarta.validation.constraints.NotBlank;
public record LoginRequest(@NotBlank String identifier, @NotBlank String password) { }
