package com.gomove.pricing.domain;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import jakarta.persistence.LockModeType;

import java.util.Optional;
import java.util.UUID;

public interface QuoteRepository extends JpaRepository<Quote, Long> {
    Optional<Quote> findByPublicIdAndCustomerPublicId(UUID quotePublicId, UUID customerPublicId);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select q from Quote q where q.publicId = :quotePublicId and q.customer.publicId = :customerPublicId")
    Optional<Quote> lockOwnedForBooking(@Param("quotePublicId") UUID quotePublicId,
                                        @Param("customerPublicId") UUID customerPublicId);
}
