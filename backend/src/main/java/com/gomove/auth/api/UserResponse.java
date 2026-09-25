package com.gomove.auth.api;
import com.gomove.auth.domain.User;
import java.util.UUID;
public record UserResponse(UUID publicId, String phone, String email, String fullName, String role, String status) {
    public static UserResponse from(User u) { return new UserResponse(u.getPublicId(),u.getPhone(),u.getEmail(),u.getFullName(),u.getRole().name(),u.getStatus().name()); }
}
