package com.gomove.geocoding.service;

import com.gomove.common.exception.DomainException;
import com.gomove.geocoding.api.PlaceResponse;
import com.gomove.geocoding.infrastructure.PhotonGeocoder;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class GeocodingServiceTest {
    private final PhotonGeocoder provider = mock(PhotonGeocoder.class);
    private final GeocodingService service = new GeocodingService(provider);

    @Test
    void normalizesVietnameseSearchAndPreservesProviderResults() {
        PlaceResponse place = new PlaceResponse("Hồ Hoàn Kiếm, Hà Nội", "Hồ Hoàn Kiếm",
                null, null, "Hà Nội", 21.0287, 105.8524, PlaceResponse.OSM_ATTRIBUTION);
        when(provider.search("Hồ Hoàn Kiếm")).thenReturn(List.of(place));

        assertThat(service.search("  Hồ Hoàn Kiếm  ")).containsExactly(place);
        verify(provider).search("Hồ Hoàn Kiếm");
    }

    @Test
    void rejectsInvalidOrSensitiveQueriesBeforeThirdPartyCall() {
        String[] invalid = {null, "", "ab", "a".repeat(101), "road\nBearer secret",
                "name@example.com", "0912345678", "+84 912 345 678",
                "67483039-c78d-4a13-9cb5-759e2ad16fc9",
                "abcdefgh.abcdefgh.abcdefgh"};
        for (String query : invalid) {
            assertThatThrownBy(() -> service.search(query)).isInstanceOf(DomainException.class)
                    .satisfies(error -> {
                        DomainException domain = (DomainException) error;
                        assertThat(domain.getStatus()).isEqualTo(HttpStatus.BAD_REQUEST);
                        assertThat(domain.getCode()).isEqualTo("INVALID_SEARCH_QUERY");
                    });
        }
        verifyNoInteractions(provider);
    }

    @Test
    void reverseRejectsMissingMalformedNonFiniteAndOutOfRangeCoordinates() {
        String[][] invalid = {{null, "105"}, {"21", null}, {"bad", "105"},
                {"NaN", "105"}, {"Infinity", "105"}, {"91", "105"},
                {"21", "181"}};
        for (String[] pair : invalid) {
            assertThatThrownBy(() -> service.reverse(pair[0], pair[1]))
                    .isInstanceOf(DomainException.class)
                    .satisfies(error -> {
                        DomainException domain = (DomainException) error;
                        assertThat(domain.getStatus()).isEqualTo(HttpStatus.BAD_REQUEST);
                        assertThat(domain.getCode()).isEqualTo("INVALID_COORDINATES");
                    });
        }
        verifyNoInteractions(provider);
    }

    @Test
    void reversePassesExactSelectedCoordinatesAndAllowsNoNearbyAddress() {
        when(provider.reverse(21.0287, 105.8524)).thenReturn(null);
        assertThat(service.reverse("21.0287", "105.8524")).isNull();
        verify(provider).reverse(21.0287, 105.8524);
    }
}
