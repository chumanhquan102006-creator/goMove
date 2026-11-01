package com.gomove.geocoding.service;

import com.gomove.common.exception.DomainException;
import com.gomove.geocoding.api.PlaceResponse;
import com.gomove.geocoding.infrastructure.PhotonGeocoder;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;

import java.text.Normalizer;
import java.util.List;
import java.util.regex.Pattern;

@Service
public class GeocodingService {
    // Search text is sent to a third party. Reject obvious account identifiers and secrets.
    private static final Pattern PHONE = Pattern.compile("(?<![\\p{L}\\d])\\+?\\d(?:[\\s().-]?\\d){8,}(?![\\p{L}\\d])");
    private static final Pattern UUID = Pattern.compile("(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}");
    private static final Pattern TOKEN = Pattern.compile("[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}");
    private final PhotonGeocoder provider;

    public GeocodingService(PhotonGeocoder provider) { this.provider = provider; }

    public List<PlaceResponse> search(String q) {
        if (q == null) throw invalidQuery();
        String query = Normalizer.normalize(q.strip(), Normalizer.Form.NFC);
        int length = query.codePointCount(0, query.length());
        if (length < 3 || length > 100 || query.codePoints().anyMatch(Character::isISOControl)
                || query.indexOf('@') >= 0 || PHONE.matcher(query).find()
                || UUID.matcher(query).find() || TOKEN.matcher(query).find()) throw invalidQuery();
        return provider.search(query);
    }

    public PlaceResponse reverse(double latitude, double longitude) {
        if (!Double.isFinite(latitude) || latitude < -90 || latitude > 90
                || !Double.isFinite(longitude) || longitude < -180 || longitude > 180) {
            throw invalidCoordinates();
        }
        return provider.reverse(latitude, longitude);
    }

    public PlaceResponse reverse(String latitude, String longitude) {
        if (latitude == null || longitude == null) throw invalidCoordinates();
        try {
            return reverse(Double.parseDouble(latitude), Double.parseDouble(longitude));
        } catch (NumberFormatException ex) {
            throw invalidCoordinates();
        }
    }

    private DomainException invalidCoordinates() {
        return new DomainException(HttpStatus.BAD_REQUEST, "INVALID_COORDINATES", "Invalid coordinates");
    }

    private DomainException invalidQuery() {
        return new DomainException(HttpStatus.BAD_REQUEST, "INVALID_SEARCH_QUERY", "Invalid search query");
    }
}
