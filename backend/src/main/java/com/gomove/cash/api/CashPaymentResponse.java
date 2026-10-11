package com.gomove.cash.api;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

public record CashPaymentResponse(UUID paymentPublicId, UUID bookingPublicId,
                                  String method, String status, BigDecimal amount,
                                  String currency, Instant paidAt) {}
