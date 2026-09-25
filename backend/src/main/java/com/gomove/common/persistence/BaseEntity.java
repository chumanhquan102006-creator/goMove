package com.gomove.common.persistence;

import jakarta.persistence.*;
import java.time.Instant;
import java.util.UUID;

@MappedSuperclass
public abstract class BaseEntity {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY) protected Long id;
    @Column(name = "public_id", nullable = false, unique = true, updatable = false) protected UUID publicId;
    @Version @Column(nullable = false) protected Long version;
    @Column(name = "created_at", nullable = false, updatable = false) protected Instant createdAt;
    @Column(name = "updated_at", nullable = false) protected Instant updatedAt;
    @PrePersist protected void onCreate() { Instant now = Instant.now(); if (publicId == null) publicId = UUID.randomUUID(); createdAt = now; updatedAt = now; }
    @PreUpdate protected void onUpdate() { updatedAt = Instant.now(); }
    public Long getId() { return id; }
    public UUID getPublicId() { return publicId; }
    public Long getVersion() { return version; }
    public Instant getCreatedAt() { return createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
}
