package com.gomove.driver;

import com.gomove.auth.domain.*;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.driver.domain.*;
import com.gomove.vehicle.domain.*;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.web.servlet.MockMvc;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@AutoConfigureMockMvc
class DriverAuthorizationIntegrationTest extends BaseIntegrationTest {
    @Autowired MockMvc mvc;
    @Autowired UserRepository users;
    @Autowired DriverRepository drivers;
    @Autowired VehicleRepository vehicles;
    @Autowired JwtTokenProvider jwt;
    @Autowired PasswordEncoder passwords;

    @Test void publicRegistrationStillIgnoresRoleEscalationAndUsesBcrypt12() throws Exception {
        String phone = phone();
        mvc.perform(post("/api/v1/auth/register").contentType(MediaType.APPLICATION_JSON)
                        .content("{\"phone\":\"" + phone + "\",\"email\":\"register-" + code() + "@example.test\",\"password\":\"password123\",\"fullName\":\"Customer\",\"role\":\"ADMIN\"}"))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.data.role").value("CUSTOMER"));
        assertThat(users.findByPhone(phone).orElseThrow().getRole()).isEqualTo(UserRole.CUSTOMER);
        assertThat(passwords.encode("password123")).matches("^\\$2[aby]\\$12\\$.*");
    }

    @Test void customerCanOnboardOnlySelfAndCannotOnboardTwice() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        User otherCustomer = user(UserRole.CUSTOMER);
        String body = "{\"licenseNumber\":\"LIC-" + code() + "\",\"userPublicId\":\"" + otherCustomer.getPublicId() + "\"}";

        mvc.perform(post("/api/v1/drivers/onboarding").header("Authorization", bearer(customer)).contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data.userPublicId").value(customer.getPublicId().toString()))
                .andExpect(jsonPath("$.data.approvalStatus").value("PENDING"));
        assertThat(drivers.findByUserId(customer.getId())).isPresent();
        assertThat(drivers.findByUserId(otherCustomer.getId())).isEmpty();
        assertThat(users.findById(customer.getId()).orElseThrow().getRole()).isEqualTo(UserRole.DRIVER);

        mvc.perform(post("/api/v1/drivers/onboarding").header("Authorization", bearerWithRole(customer, UserRole.CUSTOMER)).contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isForbidden());
    }

    @Test void approvalRequiresAdmin() throws Exception {
        Driver driver = driver(UserRole.DRIVER, DriverApprovalStatus.PENDING);
        User customer = user(UserRole.CUSTOMER);
        User anotherDriver = driver(UserRole.DRIVER, DriverApprovalStatus.PENDING).getUser();
        String path = "/api/v1/drivers/" + driver.getPublicId() + "/approval-status";
        String body = "{\"status\":\"APPROVED\"}";

        mvc.perform(patch(path).contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isUnauthorized());
        mvc.perform(patch(path).header("Authorization", bearer(customer)).contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isForbidden());
        mvc.perform(patch(path).header("Authorization", bearer(anotherDriver)).contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isForbidden());

        User admin = user(UserRole.ADMIN);
        mvc.perform(patch(path).header("Authorization", bearer(admin)).contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.approvalStatus").value("APPROVED"));
    }

    @Test void operatingStatusIsDriverSelfServiceOnly() throws Exception {
        Driver driverA = driver(UserRole.DRIVER, DriverApprovalStatus.APPROVED);
        activeVehicle(driverA);
        Driver driverB = driver(UserRole.DRIVER, DriverApprovalStatus.APPROVED);
        User customer = user(UserRole.CUSTOMER);
        String body = "{\"status\":\"ONLINE\"}";

        mvc.perform(patch("/api/v1/drivers/me/operating-status").contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isUnauthorized());
        mvc.perform(patch("/api/v1/drivers/me/operating-status").header("Authorization", bearer(customer)).contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isForbidden());
        mvc.perform(patch("/api/v1/drivers/me/operating-status").header("Authorization", bearer(driverA.getUser())).contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.publicId").value(driverA.getPublicId().toString()));
        mvc.perform(patch("/api/v1/drivers/" + driverB.getPublicId() + "/operating-status").header("Authorization", bearer(driverA.getUser())).contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isNotFound());
        assertThat(drivers.findById(driverB.getId()).orElseThrow().getOperatingStatus()).isEqualTo(DriverOperatingStatus.OFFLINE);
    }

    @Test void vehicleApisAreScopedToAuthenticatedDriver() throws Exception {
        Driver driverA = driver(UserRole.DRIVER, DriverApprovalStatus.APPROVED);
        Driver driverB = driver(UserRole.DRIVER, DriverApprovalStatus.APPROVED);
        Vehicle vehicleB = activeVehicle(driverB);
        User customer = user(UserRole.CUSTOMER);
        String addBody = "{\"licensePlate\":\"API-" + code() + "\",\"vehicleType\":\"MOTORBIKE\",\"brand\":\"Honda\",\"model\":\"Wave\",\"color\":\"Blue\"}";
        String base = "/api/v1/drivers/me/vehicles";

        mvc.perform(get(base)).andExpect(status().isUnauthorized());
        mvc.perform(get(base).header("Authorization", bearer(customer))).andExpect(status().isForbidden());
        mvc.perform(post(base).header("Authorization", bearer(driverA.getUser())).contentType(MediaType.APPLICATION_JSON).content(addBody))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.driverPublicId").value(driverA.getPublicId().toString()));
        mvc.perform(get(base).header("Authorization", bearer(driverA.getUser()))).andExpect(status().isOk()).andExpect(jsonPath("$.data.length()").value(1));
        mvc.perform(patch(base + "/" + vehicleB.getPublicId() + "/activate").header("Authorization", bearer(driverA.getUser())))
                .andExpect(status().isNotFound());
        assertThat(vehicles.findById(vehicleB.getId()).orElseThrow().isActive()).isTrue();
    }

    private User user(UserRole role) {
        User user = users.saveAndFlush(new User(phone(), "user-" + code() + "@example.test", passwords.encode("password123"), "Test User"));
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private Driver driver(UserRole role, DriverApprovalStatus approval) {
        User user = user(role);
        Driver driver = new Driver(user, "LIC-" + code());
        driver.setApprovalStatus(approval);
        return drivers.saveAndFlush(driver);
    }

    private Vehicle activeVehicle(Driver driver) {
        Vehicle vehicle = new Vehicle(driver, "CAR-" + code(), VehicleType.MOTORBIKE, "Honda", "Wave", "Blue");
        vehicle.setActive(true);
        return vehicles.saveAndFlush(vehicle);
    }

    private String bearer(User user) { return "Bearer " + jwt.createAccessToken(user); }

    private String bearerWithRole(User user, UserRole role) {
        User original = user;
        UserRole originalRole = original.getRole();
        original.setRole(role);
        String token = bearer(original);
        original.setRole(originalRole);
        return token;
    }

    private String phone() { return "09" + Long.toUnsignedString(System.nanoTime(), 36); }
    private String code() { return UUID.randomUUID().toString().substring(0, 8); }
}
