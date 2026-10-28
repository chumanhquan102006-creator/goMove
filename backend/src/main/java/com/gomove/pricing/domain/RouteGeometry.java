package com.gomove.pricing.domain;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;

/** An immutable GeoJSON LineString, with coordinate pairs in longitude, latitude order. */
public record RouteGeometry(String type, List<List<BigDecimal>> coordinates) {
    public static final int MAX_VERTICES = 8192;
    public static final int MAX_JSON_BYTES = 512 * 1024;
    private static final double MAX_ENDPOINT_METERS = 500;

    public RouteGeometry {
        if (!"LineString".equals(type) || coordinates == null
                || coordinates.size() < 2 || coordinates.size() > MAX_VERTICES) {
            throw new IllegalArgumentException("Invalid route LineString");
        }
        List<List<BigDecimal>> copied = new ArrayList<>(coordinates.size());
        for (List<BigDecimal> pair : coordinates) {
            if (pair == null || pair.size() != 2 || !valid(pair.get(0), 180)
                    || !valid(pair.get(1), 90)) {
                throw new IllegalArgumentException("Invalid route coordinate");
            }
            copied.add(List.copyOf(pair));
        }
        coordinates = List.copyOf(copied);
    }

    private static boolean valid(BigDecimal value, int bound) {
        return value != null && value.precision() <= 18 && value.scale() <= 12
                && value.compareTo(BigDecimal.valueOf(-bound)) >= 0
                && value.compareTo(BigDecimal.valueOf(bound)) <= 0;
    }

    public void validateEndpoints(GeoCoordinate pickup, GeoCoordinate dropoff) {
        if (pickup == null || dropoff == null) throw new IllegalArgumentException("Route endpoints are required");
        List<BigDecimal> first = coordinates.getFirst();
        List<BigDecimal> last = coordinates.getLast();
        double forward = distanceMeters(first, pickup) + distanceMeters(last, dropoff);
        double reverse = distanceMeters(first, dropoff) + distanceMeters(last, pickup);
        if (distanceMeters(first, pickup) > MAX_ENDPOINT_METERS
                || distanceMeters(last, dropoff) > MAX_ENDPOINT_METERS
                || reverse + 5 < forward) {
            throw new IllegalArgumentException("Route endpoints do not match the requested direction");
        }
    }

    private static double distanceMeters(List<BigDecimal> pair, GeoCoordinate point) {
        double lat1 = Math.toRadians(pair.get(1).doubleValue());
        double lat2 = Math.toRadians(point.latitude().doubleValue());
        double deltaLat = lat2 - lat1;
        double deltaLon = Math.toRadians(point.longitude().doubleValue()
                - pair.get(0).doubleValue());
        double a = Math.pow(Math.sin(deltaLat / 2), 2)
                + Math.cos(lat1) * Math.cos(lat2) * Math.pow(Math.sin(deltaLon / 2), 2);
        return 2 * 6_371_000 * Math.asin(Math.min(1, Math.sqrt(a)));
    }
}
