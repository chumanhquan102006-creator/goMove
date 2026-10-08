package com.gomove.pricing.domain;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;
import java.util.UUID;

public interface QuoteRepository extends JpaRepository<Quote, Long> {
    Optional<Quote> findByPublicIdAndCustomerPublicId(UUID quotePublicId, UUID customerPublicId);
}
