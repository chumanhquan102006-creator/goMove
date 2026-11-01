package com.gomove.admin.api;

import java.math.BigDecimal;

// All counters are lifetime totals at query time. Active means any nonterminal Booking.
// Collectible pending cash is only a COMPLETED Booking with a PENDING payment.
public record AdminDashboard(long customers, long drivers, long pendingApprovals,
                             long driversOnline, long driversOffline, long driversBusy,
                             long activeBookings, long completedBookings, long cancelledBookings,
                             long noDriverAvailableBookings, long paidCashPayments,
                             long collectiblePendingCashPayments, BigDecimal collectiblePendingCashAmount,
                             long voidCashPayments, BigDecimal voidCashAmount) {}
