package com.gomove.review.api;

import java.util.List;

public record QualityCaseDetailResponse(QualityCaseResponse qualityCase,
                                        List<QualityRatingEvidence> recentRatings,
                                        List<QualityActionResponse> actions) {}
