package com.gomove.booking.domain;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface BookingRepository extends JpaRepository<Booking, Long> {
    @Query("select b from Booking b join fetch b.quote where b.publicId = :bookingPublicId and b.customer.publicId = :customerPublicId")
    Optional<Booking> findOwned(@Param("bookingPublicId") UUID bookingPublicId,
                                @Param("customerPublicId") UUID customerPublicId);
    long countByQuoteId(Long quoteId);
}
