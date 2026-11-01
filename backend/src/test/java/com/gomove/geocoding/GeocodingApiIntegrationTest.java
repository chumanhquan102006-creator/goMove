package com.gomove.geocoding;

import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.auth.domain.UserRole;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.geocoding.api.PlaceResponse;
import com.gomove.geocoding.infrastructure.PhotonGeocoder;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import java.util.List;
import java.util.UUID;

import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@AutoConfigureMockMvc
class GeocodingApiIntegrationTest extends BaseIntegrationTest {
    private static final String SEARCH = "/api/v1/locations/search";
    private static final String REVERSE = "/api/v1/locations/reverse";

    @Autowired MockMvc mvc;
    @Autowired UserRepository users;
    @Autowired JwtTokenProvider jwt;
    @MockitoBean PhotonGeocoder provider;

    @Test
    void customerSearchUsesJwtRoleAndNeverCallsProviderForUnauthenticatedOrDriver() throws Exception {
        mvc.perform(get(SEARCH).param("q", "Hồ Hoàn Kiếm"))
                .andExpect(status().isUnauthorized());
        mvc.perform(get(SEARCH).header("Authorization", bearer(user(UserRole.DRIVER)))
                        .param("q", "Hồ Hoàn Kiếm"))
                .andExpect(status().isForbidden());
        verifyNoInteractions(provider);

        PlaceResponse place = new PlaceResponse("Hồ Hoàn Kiếm, Hà Nội", "Hồ Hoàn Kiếm",
                null, null, "Hà Nội", 21.0287, 105.8524, PlaceResponse.OSM_ATTRIBUTION);
        when(provider.search("Hồ Hoàn Kiếm")).thenReturn(List.of(place));
        mvc.perform(get(SEARCH).header("Authorization", bearer(user(UserRole.CUSTOMER)))
                        .param("q", "Hồ Hoàn Kiếm"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data[0].label").value("Hồ Hoàn Kiếm, Hà Nội"))
                .andExpect(jsonPath("$.data[0].latitude").value(21.0287))
                .andExpect(jsonPath("$.data[0].longitude").value(105.8524))
                .andExpect(jsonPath("$.data[0].attribution").value(PlaceResponse.OSM_ATTRIBUTION));
    }

    @Test
    void invalidSearchAndReverseParametersReturn400WithoutProviderCall() throws Exception {
        String auth = bearer(user(UserRole.CUSTOMER));
        mvc.perform(get(SEARCH).header("Authorization", auth))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("INVALID_SEARCH_QUERY"));
        mvc.perform(get(SEARCH).header("Authorization", auth).param("q", "ab"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("INVALID_SEARCH_QUERY"));
        mvc.perform(get(SEARCH).header("Authorization", auth).param("q", "0912345678"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("INVALID_SEARCH_QUERY"));
        mvc.perform(get(REVERSE).header("Authorization", auth))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("INVALID_COORDINATES"));
        mvc.perform(get(REVERSE).header("Authorization", auth)
                        .param("latitude", "wrong").param("longitude", "105.8524"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("INVALID_COORDINATES"));
        mvc.perform(get(REVERSE).header("Authorization", auth)
                        .param("latitude", "21.0287").param("longitude", "181"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("INVALID_COORDINATES"));
        verifyNoInteractions(provider);
    }

    @Test
    void driverMayReverseAfterAuthenticationAndMissingAddressIsExplicitlyNull() throws Exception {
        String auth = bearer(user(UserRole.DRIVER));
        mvc.perform(get(REVERSE).param("latitude", "21.0287").param("longitude", "105.8524"))
                .andExpect(status().isUnauthorized());
        when(provider.reverse(21.0287, 105.8524)).thenReturn(null);
        mvc.perform(get(REVERSE).header("Authorization", auth)
                        .param("latitude", "21.0287").param("longitude", "105.8524"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data").value(org.hamcrest.Matchers.nullValue()));
    }

    @Test
    void authenticatedAccountGets429AfterCombinedGeocodingBudget() throws Exception {
        String auth = bearer(user(UserRole.CUSTOMER));
        when(provider.search("Hà Nội")).thenReturn(List.of());
        for (int i = 0; i < 30; i++) {
            mvc.perform(get(SEARCH).header("Authorization", auth).param("q", "Hà Nội"))
                    .andExpect(status().isOk());
        }
        mvc.perform(get(REVERSE).header("Authorization", auth)
                        .param("latitude", "21.0287").param("longitude", "105.8524"))
                .andExpect(status().isTooManyRequests())
                .andExpect(jsonPath("$.code").value("GEOCODING_RATE_LIMITED"));
        verify(provider, times(30)).search("Hà Nội");
        verify(provider, times(0)).reverse(21.0287, 105.8524);
    }

    private User user(UserRole role) {
        String unique = UUID.randomUUID().toString().substring(0, 8);
        User user = users.saveAndFlush(new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "geocode-" + unique + "@example.test", "hash", "Geocoding Test"));
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private String bearer(User user) {
        return "Bearer " + jwt.createAccessToken(user);
    }
}
