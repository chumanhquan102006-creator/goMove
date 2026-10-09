package com.gomove.dispatch.api;

import com.gomove.dispatch.domain.DriverOfferStatus;

import java.time.Instant;
import java.util.UUID;

public record OfferDecisionResponse(UUID offerPublicId, DriverOfferStatus status, Instant respondedAt) {}
