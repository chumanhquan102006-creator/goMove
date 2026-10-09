package com.gomove.common.security;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.common.api.ErrorResponse;
import org.springframework.context.annotation.*;
import org.springframework.http.MediaType;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;
import java.util.Map;
@Configuration @EnableWebSecurity @EnableMethodSecurity
public class SecurityConfiguration {
    @Bean PasswordEncoder passwordEncoder() { return new BCryptPasswordEncoder(12); }
    @Bean SecurityFilterChain securityFilterChain(HttpSecurity http, JwtAuthenticationFilter jwtFilter, ObjectMapper mapper) throws Exception {
        return http.csrf(csrf -> csrf.disable()).sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS)).authorizeHttpRequests(auth -> auth
            .requestMatchers("/actuator/**","/swagger-ui/**","/swagger-ui.html","/v3/api-docs/**","/api/v1/auth/register","/api/v1/auth/login","/api/v1/auth/refresh","/api/v1/auth/logout","/ws","/ws/**").permitAll().anyRequest().authenticated())
            .exceptionHandling(e -> e.authenticationEntryPoint((req,res,x) -> { res.setStatus(401);res.setContentType(MediaType.APPLICATION_JSON_VALUE);mapper.writeValue(res.getOutputStream(), ErrorResponse.of("UNAUTHORIZED","Unauthorized",req.getRequestURI(),Map.of())); }))
            .addFilterBefore(jwtFilter, UsernamePasswordAuthenticationFilter.class).build();
    }
}
