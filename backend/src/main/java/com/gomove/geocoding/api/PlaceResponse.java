package com.gomove.geocoding.api;

/** Address fields are provider metadata; coordinates remain the routing input. */
public record PlaceResponse(String label, String name, String street, String district,
                            String city, double latitude, double longitude, String attribution) {
    public static final String OSM_ATTRIBUTION = "© OpenStreetMap contributors";
}
