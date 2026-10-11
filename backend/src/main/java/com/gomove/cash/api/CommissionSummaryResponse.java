package com.gomove.cash.api;

import java.math.BigDecimal;

public record CommissionSummaryResponse(BigDecimal accruedCommissionReceivable,
                                        BigDecimal outstandingCommissionDue,
                                        String currency) {}
