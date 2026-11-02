package com.gomove.review.api;

import java.util.List;

public record RewardHistoryResponse(List<RewardEventResponse> items, int page,
                                    int size, long total, boolean hasNext) {}
