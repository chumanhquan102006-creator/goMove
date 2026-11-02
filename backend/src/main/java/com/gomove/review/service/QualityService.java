package com.gomove.review.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.common.exception.DomainException;
import com.gomove.driver.domain.DriverApprovalStatus;
import com.gomove.driver.service.DriverService;
import com.gomove.review.api.*;
import com.gomove.review.infrastructure.QualityStore;
import com.gomove.review.infrastructure.ReviewStore;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

@Service
public class QualityService {
    private final QualityStore cases;
    private final ReviewStore reviews;
    private final DriverService drivers;

    public QualityService(QualityStore cases, ReviewStore reviews, DriverService drivers) {
        this.cases = cases;
        this.reviews = reviews;
        this.drivers = drivers;
    }

    @Transactional(readOnly = true)
    public QualityCasePageResponse adminCases(UserRole role, String status, int page, int size) {
        requireRole(role, UserRole.ADMIN);
        validatePage(page, size);
        if (status != null && !status.equals("OPEN") && !status.equals("WARNED")
                && !status.equals("DISPUTED") && !status.equals("SUSPENDED")
                && !status.equals("DISMISSED")) {
            throw new DomainException(HttpStatus.BAD_REQUEST, "INVALID_QUALITY_STATUS", "Unsupported case status");
        }
        return cases.page(status, null, page, size);
    }

    @Transactional(readOnly = true)
    public QualityCaseDetailResponse adminDetail(UserRole role, UUID casePublicId) {
        requireRole(role, UserRole.ADMIN);
        return cases.detail(requiredCase(casePublicId, false));
    }

    @Transactional
    public QualityCaseDetailResponse adminAction(UUID adminId, UserRole role,
                                                 UUID casePublicId, QualityActionRequest request) {
        requireRole(role, UserRole.ADMIN);
        if (request == null || request.action() == null) {
            throw new DomainException(HttpStatus.BAD_REQUEST, "INVALID_QUALITY_ACTION", "Action is required");
        }
        String action = request.action().trim().toUpperCase(java.util.Locale.ROOT);
        if (!action.equals("WARN") && !action.equals("SUSPEND") && !action.equals("DISMISS")) {
            throw new DomainException(HttpStatus.BAD_REQUEST, "INVALID_QUALITY_ACTION", "Unsupported action");
        }
        String note = normalize(request.note());
        if (request.note() != null && request.note().length() > 500
                || (!action.equals("DISMISS") && note == null)) {
            throw new DomainException(HttpStatus.BAD_REQUEST, "INVALID_QUALITY_NOTE", "A short explanation is required");
        }
        var row = requiredCase(casePublicId, true);
        String old = row.response().status();
        if (!old.equals("OPEN") && !old.equals("WARNED") && !old.equals("DISPUTED")) {
            throw new DomainException(HttpStatus.CONFLICT, "QUALITY_CASE_CLOSED", "Case is already closed");
        }
        if (action.equals("WARN") && old.equals("WARNED")) {
            throw new DomainException(HttpStatus.CONFLICT, "QUALITY_ACTION_UNCHANGED", "Driver is already warned for this case");
        }
        if (action.equals("SUSPEND")) {
            // Reuse the existing Driver lock and active-Booking protection. Both audits commit together.
            drivers.updateApprovalStatusAsAdmin(adminId, UserRole.ADMIN,
                    row.response().driverPublicId(), DriverApprovalStatus.SUSPENDED);
        }
        String next = switch (action) {
            case "WARN" -> "WARNED";
            case "SUSPEND" -> "SUSPENDED";
            default -> "DISMISSED";
        };
        cases.transition(row, next, adminId, action, note);
        return cases.detail(requiredCase(casePublicId, false));
    }

    @Transactional(readOnly = true)
    public QualityCasePageResponse ownCases(UUID driverUserId, UserRole role, int page, int size) {
        requireRole(role, UserRole.DRIVER);
        validatePage(page, size);
        long driverId = reviews.driverIdForUser(driverUserId)
                .orElseThrow(() -> new DomainException(HttpStatus.FORBIDDEN, "DRIVER_PROFILE_REQUIRED", "Driver profile is required"));
        return cases.page(null, driverId, page, size);
    }

    @Transactional
    public QualityCaseResponse dispute(UUID driverUserId, UserRole role, UUID casePublicId,
                                       QualityDisputeRequest request) {
        requireRole(role, UserRole.DRIVER);
        String reason = request == null ? null : normalize(request.reason());
        if (reason == null || request.reason().length() > 500) {
            throw new DomainException(HttpStatus.BAD_REQUEST, "INVALID_DISPUTE", "A short dispute reason is required");
        }
        long driverId = reviews.driverIdForUser(driverUserId)
                .orElseThrow(() -> new DomainException(HttpStatus.FORBIDDEN, "DRIVER_PROFILE_REQUIRED", "Driver profile is required"));
        var row = requiredCase(casePublicId, true);
        if (row.driverId() != driverId) {
            throw new DomainException(HttpStatus.NOT_FOUND, "QUALITY_CASE_NOT_FOUND", "Case not found");
        }
        if (!row.response().status().equals("OPEN") && !row.response().status().equals("WARNED")
                && !row.response().status().equals("SUSPENDED")) {
            throw new DomainException(HttpStatus.CONFLICT, "QUALITY_DISPUTE_UNAVAILABLE", "Case cannot be disputed now");
        }
        cases.transition(row, "DISPUTED", driverUserId, "DISPUTE", reason);
        return requiredCase(casePublicId, false).response();
    }

    private QualityStore.CaseRow requiredCase(UUID publicId, boolean lock) {
        return cases.find(publicId, lock)
                .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND, "QUALITY_CASE_NOT_FOUND", "Case not found"));
    }

    private static void validatePage(int page, int size) {
        if (page < 0 || page > 10_000 || size < 1 || size > 50) {
            throw new DomainException(HttpStatus.BAD_REQUEST, "INVALID_QUALITY_PAGE", "Invalid page or size");
        }
    }

    private static String normalize(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }

    private static void requireRole(UserRole actual, UserRole required) {
        if (actual != required) {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Role is not authorized");
        }
    }
}
