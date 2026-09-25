package com.gomove.auth.api;
import jakarta.validation.constraints.*;
public record RegisterRequest(@NotBlank @Size(max=20) String phone, @Email @Size(max=100) String email, @NotBlank @Size(min=8, max=128) String password, @NotBlank @Size(max=100) String fullName) { }
