package com.gomove.cash.api;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

public record CashReceiptResponse(UUID paymentPublicId, UUID bookingPublicId,
                                  String paymentStatus, String paymentMethod,
                                  BigDecimal cashCollectedAmount, String currency,
                                  BigDecimal commissionRate, BigDecimal commissionAmount,
                                  String commissionPolicyVersion, Instant paidAt,
                                  Instant driverReleasedAt) {}
