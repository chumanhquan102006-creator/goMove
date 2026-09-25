package com.gomove.auth.domain;
import org.springframework.data.jpa.repository.*;
import org.springframework.data.repository.query.Param;
import jakarta.persistence.LockModeType;
import java.util.*;
public interface UserRepository extends JpaRepository<User, Long> {
    boolean existsByPhone(String phone); boolean existsByEmail(String email); Optional<User> findByPhone(String phone); Optional<User> findByPublicId(UUID publicId);
    @Lock(LockModeType.PESSIMISTIC_WRITE) @Query("select u from User u where u.phone = :identifier or u.email = :identifier")
    Optional<User> findByIdentifierForUpdate(@Param("identifier") String identifier);
}
