package com.gomove.booking.api;

import java.util.List;

public record BookingHistoryPageResponse(
        List<BookingHistoryItemResponse> items,
        int page,
        int size,
        long totalElements,
        boolean hasNext
) {}
