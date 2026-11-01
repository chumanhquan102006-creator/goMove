package com.gomove.booking.service;

import com.gomove.auth.domain.UserRole;
import com.gomove.booking.api.BookingHistoryItemResponse;
import com.gomove.booking.api.BookingHistoryPageResponse;
import com.gomove.booking.infrastructure.BookingHistoryStore;
import com.gomove.common.exception.DomainException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

@Service
public class BookingHistoryService {
    private final BookingHistoryStore store;

    public BookingHistoryService(BookingHistoryStore store) {
        this.store = store;
    }

    @Transactional(readOnly = true)
    public BookingHistoryPageResponse completed(UUID customerPublicId, UserRole role, int page, int size) {
        if (role != UserRole.CUSTOMER) {
            throw new DomainException(HttpStatus.FORBIDDEN, "FORBIDDEN", "Customer role is required");
        }
        if (page < 0 || page > 10_000 || size < 1 || size > 50) {
            throw new DomainException(HttpStatus.BAD_REQUEST, "INVALID_PAGINATION", "Invalid history page or size");
        }
        long offset = (long) page * size;
        long total = store.countCompleted(customerPublicId);
        List<BookingHistoryItemResponse> items = store.completed(customerPublicId, size, offset);
        return new BookingHistoryPageResponse(items, page, size, total, offset + items.size() < total);
    }
}
