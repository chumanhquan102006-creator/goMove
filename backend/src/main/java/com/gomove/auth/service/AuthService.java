package com.gomove.auth.service;
import com.gomove.auth.api.*;
import com.gomove.auth.domain.*;
import com.gomove.auth.infrastructure.*;
import com.gomove.common.exception.BaseException;
import org.springframework.http.HttpStatus;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.time.Instant;
import java.util.*;

@Service
public class AuthService {
    private static final String INVALID_CREDENTIALS="Invalid credentials";
    private final UserRepository users; private final RefreshTokenRepository refreshTokens; private final PasswordEncoder encoder; private final JwtTokenProvider jwt; private final OpaqueTokenGenerator opaque; private final AuthProperties properties;
    public AuthService(UserRepository users, RefreshTokenRepository refreshTokens, PasswordEncoder encoder, JwtTokenProvider jwt, OpaqueTokenGenerator opaque, AuthProperties properties) { this.users=users;this.refreshTokens=refreshTokens;this.encoder=encoder;this.jwt=jwt;this.opaque=opaque;this.properties=properties; }
    @Transactional public UserResponse register(RegisterRequest request) {
        if (users.existsByPhone(request.phone())) throw conflict("PHONE_ALREADY_EXISTS", "Phone is already registered");
        if (request.email()!=null && !request.email().isBlank() && users.existsByEmail(request.email())) throw conflict("EMAIL_ALREADY_EXISTS", "Email is already registered");
        User user=new User(request.phone(), blankToNull(request.email()), encoder.encode(request.password()), request.fullName());
        return UserResponse.from(users.save(user));
    }
    @Transactional public AuthResponse login(LoginRequest request) {
        User user=users.findByIdentifierForUpdate(request.identifier()).orElseThrow(this::invalidCredentials);
        if (user.getStatus()==UserStatus.DISABLED) throw invalidCredentials();
        if (user.getStatus()==UserStatus.LOCKED) { if (!user.isAccountNonLocked()) throw invalidCredentials(); user.resetFailedAttempts(); }
        if (!encoder.matches(request.password(), user.getPasswordHash())) { user.incrementFailedAttempts(properties.getMaxFailedLoginAttempts(), properties.getLockDuration()); throw invalidCredentials(); }
        user.resetFailedAttempts(); return issueTokens(user);
    }
    @Transactional public AuthResponse refresh(String rawToken) {
        RefreshToken old=refreshTokens.findByTokenHashForUpdate(opaque.sha256(rawToken)).orElseThrow(this::invalidRefresh);
        if (!old.isActive()) throw invalidRefresh();
        String rawNew=opaque.generate(); RefreshToken fresh=new RefreshToken(old.getUser(), opaque.sha256(rawNew), Instant.now().plus(properties.getRefreshTokenValidity()));
        refreshTokens.save(fresh); refreshTokens.flush();
        old.revoke(fresh.getPublicId()); old.markUsed();
        return new AuthResponse(jwt.createAccessToken(old.getUser()), rawNew, "Bearer", jwt.getAccessTokenExpiresInSeconds(), UserResponse.from(old.getUser()));
    }
    @Transactional public void logout(String rawToken) { refreshTokens.findByTokenHashForUpdate(opaque.sha256(rawToken)).filter(RefreshToken::isActive).ifPresent(token -> token.revoke(null)); }
    @Transactional(readOnly=true) public UserResponse me(UUID publicId) { return UserResponse.from(users.findByPublicId(publicId).orElseThrow(() -> new BaseException(HttpStatus.UNAUTHORIZED,"UNAUTHORIZED","Unauthorized"))); }
    private AuthResponse issueTokens(User user) { String raw=opaque.generate(); refreshTokens.save(new RefreshToken(user, opaque.sha256(raw), Instant.now().plus(properties.getRefreshTokenValidity()))); return new AuthResponse(jwt.createAccessToken(user), raw, "Bearer", jwt.getAccessTokenExpiresInSeconds(), UserResponse.from(user)); }
    private BaseException conflict(String code,String msg) { return new BaseException(HttpStatus.CONFLICT,code,msg); } private BaseException invalidCredentials() { return new BaseException(HttpStatus.UNAUTHORIZED,"INVALID_CREDENTIALS",INVALID_CREDENTIALS); } private BaseException invalidRefresh() { return new BaseException(HttpStatus.UNAUTHORIZED,"INVALID_REFRESH_TOKEN","Invalid refresh token"); } private String blankToNull(String value) { return value==null || value.isBlank()?null:value; }
}
