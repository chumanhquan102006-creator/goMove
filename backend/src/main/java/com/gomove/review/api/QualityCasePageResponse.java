package com.gomove.review.api;

import java.util.List;

public record QualityCasePageResponse(List<QualityCaseResponse> items, int page,
                                      int size, long total, boolean hasNext) {}
