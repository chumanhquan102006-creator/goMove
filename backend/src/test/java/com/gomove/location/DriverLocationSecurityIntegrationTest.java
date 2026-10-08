package com.gomove.location;

import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.auth.domain.UserRole;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.driver.domain.Driver;
import com.gomove.driver.domain.DriverApprovalStatus;
import com.gomove.driver.domain.DriverOperatingStatus;
import com.gomove.driver.domain.DriverRepository;
import com.gomove.location.domain.DriverLocationRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.EnumSource;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.web.servlet.MockMvc;

import java.util.UUID;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@AutoConfigureMockMvc
class DriverLocationSecurityIntegrationTest extends BaseIntegrationTest {
    private static final String PATH = "/api/v1/drivers/me/location";
    private static final String VALID_BODY = """
            {"latitude":21.0287,"longitude":105.8524,"accuracy":8.5,"bearing":120.0}
            """;

    @Autowired MockMvc mvc;
    @Autowired UserRepository users;
    @Autowired DriverRepository drivers;
    @Autowired DriverLocationRepository locations;
    @Autowired JwtTokenProvider jwt;
    @Autowired PasswordEncoder passwords;

    @Test
    void unauthenticatedRequestIsRejected() throws Exception {
        mvc.perform(put(PATH).contentType(MediaType.APPLICATION_JSON).content(VALID_BODY))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.code").value("UNAUTHORIZED"));
    }

    @Test
    void customerTokenIsForbidden() throws Exception {
        User customer = user(UserRole.CUSTOMER);

        mvc.perform(put(PATH)
                        .header("Authorization", bearer(customer))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(VALID_BODY))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.code").value("FORBIDDEN"));
    }

    @ParameterizedTest
    @EnumSource(value = DriverOperatingStatus.class, names = {"ONLINE", "BUSY"})
    void approvedOnlineOrBusyDriverCanUpdateOwnLocation(DriverOperatingStatus operatingStatus) throws Exception {
        Driver driver = driver(DriverApprovalStatus.APPROVED, operatingStatus);

        mvc.perform(put(PATH)
                        .header("Authorization", bearer(driver.getUser()))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(VALID_BODY))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.code").value("DRIVER_LOCATION_UPDATED"))
                .andExpect(jsonPath("$.data.latitude").value(21.0287))
                .andExpect(jsonPath("$.data.longitude").value(105.8524))
                .andExpect(jsonPath("$.data.accuracy").value(8.5))
                .andExpect(jsonPath("$.data.bearing").value(120.0));

        assertThat(locations.findByDriverId(driver.getId())).isPresent();
        assertThat(drivers.findById(driver.getId()).orElseThrow().getOperatingStatus())
                .isEqualTo(operatingStatus);
    }

    @ParameterizedTest
    @MethodSource("ineligibleStates")
    void ineligibleDriverStateCannotUpdateLocation(
            DriverApprovalStatus approvalStatus,
            DriverOperatingStatus operatingStatus
    ) throws Exception {
        Driver driver = driver(approvalStatus, operatingStatus);

        mvc.perform(put(PATH)
                        .header("Authorization", bearer(driver.getUser()))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(VALID_BODY))
                .andExpect(status().isConflict());

        assertThat(locations.findByDriverId(driver.getId())).isEmpty();
    }

    @ParameterizedTest(name = "invalid location payload {index}")
    @MethodSource("invalidPayloads")
    void invalidCoordinateAccuracyOrBearingReturnsValidationError(String body) throws Exception {
        Driver driver = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE);

        mvc.perform(put(PATH)
                        .header("Authorization", bearer(driver.getUser()))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(body))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("VALIDATION_ERROR"));

        assertThat(locations.findByDriverId(driver.getId())).isEmpty();
    }

    @Test
    void requestIdentityFieldsCannotImpersonateAnotherDriver() throws Exception {
        Driver authenticated = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE);
        Driver other = driver(DriverApprovalStatus.APPROVED, DriverOperatingStatus.ONLINE);
        String body = """
                {"latitude":21.0287,"longitude":105.8524,"accuracy":8.5,"bearing":120.0,
                 "driverId":%d,"driverPublicId":"%s","userPublicId":"%s","role":"ADMIN"}
                """.formatted(other.getId(), other.getPublicId(), other.getUser().getPublicId());

        mvc.perform(put(PATH)
                        .header("Authorization", bearer(authenticated.getUser()))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(body))
                .andExpect(status().isOk());

        assertThat(locations.findByDriverId(authenticated.getId())).isPresent();
        assertThat(locations.findByDriverId(other.getId())).isEmpty();
    }

    private static Stream<Arguments> ineligibleStates() {
        return Stream.of(
                Arguments.of(DriverApprovalStatus.APPROVED, DriverOperatingStatus.OFFLINE),
                Arguments.of(DriverApprovalStatus.PENDING, DriverOperatingStatus.OFFLINE),
                Arguments.of(DriverApprovalStatus.REJECTED, DriverOperatingStatus.OFFLINE),
                Arguments.of(DriverApprovalStatus.SUSPENDED, DriverOperatingStatus.OFFLINE)
        );
    }

    private static Stream<Arguments> invalidPayloads() {
        return Stream.of(
                Arguments.of("{\"latitude\":-90.1,\"longitude\":105.8524}"),
                Arguments.of("{\"latitude\":90.1,\"longitude\":105.8524}"),
                Arguments.of("{\"latitude\":21.0287,\"longitude\":-180.1}"),
                Arguments.of("{\"latitude\":21.0287,\"longitude\":180.1}"),
                Arguments.of("{\"latitude\":21.0287,\"longitude\":105.8524,\"accuracy\":-0.1}"),
                Arguments.of("{\"latitude\":21.0287,\"longitude\":105.8524,\"bearing\":-0.1}"),
                Arguments.of("{\"latitude\":21.0287,\"longitude\":105.8524,\"bearing\":360.0}")
        );
    }

    private User user(UserRole role) {
        User user = users.saveAndFlush(new User(
                phone(),
                "location-" + code() + "@example.test",
                passwords.encode("password123"),
                "Location Test"
        ));
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private Driver driver(DriverApprovalStatus approvalStatus, DriverOperatingStatus operatingStatus) {
        Driver driver = new Driver(user(UserRole.DRIVER), "LOC-" + code());
        driver.setApprovalStatus(approvalStatus);
        driver.setOperatingStatus(operatingStatus);
        return drivers.saveAndFlush(driver);
    }

    private String bearer(User user) {
        return "Bearer " + jwt.createAccessToken(user);
    }

    private String phone() {
        return "09" + Long.toUnsignedString(System.nanoTime(), 36);
    }

    private String code() {
        return UUID.randomUUID().toString().substring(0, 8);
    }
}
