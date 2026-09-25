package com.gomove.auth.api;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.auth.domain.*;
import com.gomove.common.BaseIntegrationTest;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.*;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.web.servlet.MockMvc;
import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
@AutoConfigureMockMvc
class AuthControllerIntegrationTest extends BaseIntegrationTest {
    @Autowired MockMvc mvc; @Autowired ObjectMapper json; @Autowired UserRepository users; @Autowired PasswordEncoder passwords;
    @Test void registerLoginMeAndRefreshRotationAreSecure() throws Exception {
        String registration="{\"phone\":\"0900000001\",\"email\":\"person@example.test\",\"password\":\"password123\",\"fullName\":\"Customer\",\"role\":\"ADMIN\"}";
        String register=mvc.perform(post("/api/v1/auth/register").contentType(MediaType.APPLICATION_JSON).content(registration)).andExpect(status().isCreated()).andExpect(jsonPath("$.data.role").value("CUSTOMER")).andReturn().getResponse().getContentAsString();
        User user=users.findByPhone("0900000001").orElseThrow(); assertThat(passwords.matches("password123",user.getPasswordHash())).isTrue(); assertThat(user.getPasswordHash()).doesNotContain("password123");
        String login=mvc.perform(post("/api/v1/auth/login").contentType(MediaType.APPLICATION_JSON).content("{\"identifier\":\"person@example.test\",\"password\":\"password123\"}")).andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
        JsonNode tokens=json.readTree(login).path("data"); String access=tokens.path("accessToken").asText(); String oldRefresh=tokens.path("refreshToken").asText();
        mvc.perform(get("/api/v1/auth/me").header("Authorization","Bearer "+access)).andExpect(status().isOk()).andExpect(jsonPath("$.data.publicId").value(json.readTree(register).path("data").path("publicId").asText()));
        String refreshed=mvc.perform(post("/api/v1/auth/refresh").contentType(MediaType.APPLICATION_JSON).content("{\"refreshToken\":\""+oldRefresh+"\"}")).andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
        assertThat(json.readTree(refreshed).path("data").path("refreshToken").asText()).isNotEqualTo(oldRefresh);
        mvc.perform(post("/api/v1/auth/refresh").contentType(MediaType.APPLICATION_JSON).content("{\"refreshToken\":\""+oldRefresh+"\"}")).andExpect(status().isUnauthorized());
    }
}
