package com.gomove.cash.api;

import java.math.BigDecimal;

public record CommissionSummaryResponse(BigDecimal accruedCommissionReceivable,
                                        BigDecimal outstandingCommissionDue,
                                        String currency,
                                        long paidTripCount,
                                        String cashCollectedAmount,
                                        String commissionDueAmount,
                                        String afterCommissionAmount) {}
