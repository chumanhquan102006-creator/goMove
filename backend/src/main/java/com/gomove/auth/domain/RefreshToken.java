package com.gomove.auth.domain;
import com.gomove.common.persistence.BaseEntity;
import jakarta.persistence.*;
import java.time.*;
import java.util.UUID;
@Entity @Table(name="refresh_tokens")
public class RefreshToken extends BaseEntity {
    @ManyToOne(fetch=FetchType.LAZY, optional=false) @JoinColumn(name="user_id", nullable=false) private User user;
    @Column(name="token_hash", nullable=false, unique=true, length=64) private String tokenHash;
    @Column(name="expires_at", nullable=false) private Instant expiresAt;
    @Column(name="revoked_at") private Instant revokedAt;
    @Column(name="replaced_by_public_id") private UUID replacedByPublicId;
    @Column(name="last_used_at") private Instant lastUsedAt;
    protected RefreshToken() { }
    public RefreshToken(User user, String tokenHash, Instant expiresAt) { this.user=user; this.tokenHash=tokenHash; this.expiresAt=expiresAt; }
    public boolean isActive() { Instant now=Instant.now(); return revokedAt == null && expiresAt.isAfter(now); }
    public void revoke(UUID replacedBy) { revokedAt=Instant.now(); replacedByPublicId=replacedBy; }
    public void markUsed() { lastUsedAt=Instant.now(); }
    public User getUser() { return user; } public String getTokenHash() { return tokenHash; } public Instant getExpiresAt() { return expiresAt; } public Instant getRevokedAt() { return revokedAt; } public UUID getReplacedByPublicId() { return replacedByPublicId; }
}
