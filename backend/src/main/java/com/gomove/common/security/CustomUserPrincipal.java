package com.gomove.common.security;
import com.gomove.auth.domain.UserRole;
import java.util.UUID;
public record CustomUserPrincipal(UUID publicId, UserRole role) { }
