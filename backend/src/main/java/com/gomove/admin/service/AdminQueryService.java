package com.gomove.admin.service;

import com.gomove.admin.api.*;
import com.gomove.admin.infrastructure.AdminQueryStore;
import com.gomove.auth.domain.UserRole;
import com.gomove.booking.domain.BookingStatus;
import com.gomove.common.exception.DomainException;
import com.gomove.driver.domain.DriverApprovalStatus;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

@Service
@Transactional(readOnly = true)
public class AdminQueryService {
    private final AdminQueryStore store;

    public AdminQueryService(AdminQueryStore store) { this.store = store; }

    public AdminPage<AdminDriver> drivers(int page, int size, String approval, String search) {
        validate(page, size, search);
        return store.drivers(approval == null ? null : parsed(DriverApprovalStatus.class, approval),
                normalized(search), page, size);
    }

    public AdminDriver driver(UUID publicId) {
        return store.driver(publicId).orElseThrow(() -> notFound("DRIVER_NOT_FOUND"));
    }

    public AdminPage<AdminAccount> accounts(int page, int size, String role, String search) {
        validate(page, size, search);
        return store.accounts(role == null ? null : parsed(UserRole.class, role),
                normalized(search), page, size);
    }

    public AdminAccount account(UUID publicId) {
        return store.account(publicId).orElseThrow(() -> notFound("ACCOUNT_NOT_FOUND"));
    }

    public AdminPage<AdminBooking> bookings(int page, int size, String status) {
        validate(page, size, null);
        return store.bookings(status == null ? null : parsed(BookingStatus.class, status), page, size);
    }

    public AdminDashboard dashboard() { return store.dashboard(); }

    private static void validate(int page, int size, String search) {
        if (page < 0 || page > 100000 || size < 1 || size > 50
                || (search != null && search.length() > 80)) {
            throw new DomainException(HttpStatus.BAD_REQUEST, "INVALID_ADMIN_QUERY", "Invalid pagination or search query");
        }
    }

    private static String normalized(String search) {
        if (search == null || search.isBlank()) return null;
        return search.trim();
    }

    private static <E extends Enum<E>> String parsed(Class<E> kind, String value) {
        try { return Enum.valueOf(kind, value).name(); }
        catch (IllegalArgumentException ex) {
            throw new DomainException(HttpStatus.BAD_REQUEST, "INVALID_ADMIN_FILTER", "Unsupported filter value");
        }
    }

    private static DomainException notFound(String code) {
        return new DomainException(HttpStatus.NOT_FOUND, code, "Resource not found");
    }
}
