package com.gomove.auth.domain;
import com.gomove.common.persistence.BaseEntity;
import jakarta.persistence.*;
import java.time.*;
@Entity @Table(name="users")
public class User extends BaseEntity {
    @Column(nullable=false, unique=true, length=20) private String phone;
    @Column(unique=true, length=100) private String email;
    @Column(name="password_hash", nullable=false, length=255) private String passwordHash;
    @Column(name="full_name", nullable=false, length=100) private String fullName;
    @Enumerated(EnumType.STRING) @Column(nullable=false, length=20) private UserRole role;
    @Enumerated(EnumType.STRING) @Column(nullable=false, length=20) private UserStatus status = UserStatus.ACTIVE;
    @Column(name="failed_login_attempts", nullable=false) private int failedLoginAttempts;
    @Column(name="locked_until") private Instant lockedUntil;
    protected User() { }
    public User(String phone, String email, String passwordHash, String fullName) { this.phone=phone; this.email=email; this.passwordHash=passwordHash; this.fullName=fullName; this.role=UserRole.CUSTOMER; }
    public void incrementFailedAttempts(int threshold, Duration lockDuration) { failedLoginAttempts++; if (failedLoginAttempts >= threshold) { status=UserStatus.LOCKED; lockedUntil=Instant.now().plus(lockDuration); } }
    public void resetFailedAttempts() { failedLoginAttempts=0; lockedUntil=null; if (status == UserStatus.LOCKED) status=UserStatus.ACTIVE; }
    public boolean isAccountNonLocked() { return status != UserStatus.LOCKED || (lockedUntil != null && !lockedUntil.isAfter(Instant.now())); }
    public String getPhone() { return phone; } public String getEmail() { return email; } public String getPasswordHash() { return passwordHash; } public String getFullName() { return fullName; } public UserRole getRole() { return role; } public UserStatus getStatus() { return status; } public int getFailedLoginAttempts() { return failedLoginAttempts; } public Instant getLockedUntil() { return lockedUntil; }
    public void setRole(UserRole role) { this.role = role; }
    public void setStatus(UserStatus status) { this.status=status; } public void setLockedUntil(Instant lockedUntil) { this.lockedUntil=lockedUntil; }
}
