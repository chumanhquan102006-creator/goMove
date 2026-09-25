package com.gomove.auth.infrastructure;
import com.gomove.auth.domain.User;
import io.jsonwebtoken.*;
import io.jsonwebtoken.security.Keys;
import org.springframework.stereotype.Component;
import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.util.*;
@Component
public class JwtTokenProvider {
    private final AuthProperties properties; private final SecretKey key;
    public JwtTokenProvider(AuthProperties properties) { this.properties=properties; if (properties.getJwtSecret()==null || properties.getJwtSecret().getBytes(StandardCharsets.UTF_8).length<32) throw new IllegalStateException("JWT_SECRET must be at least 32 bytes"); key=Keys.hmacShaKeyFor(properties.getJwtSecret().getBytes(StandardCharsets.UTF_8)); }
    public String createAccessToken(User user) { Instant now=Instant.now(); return Jwts.builder().subject(user.getPublicId().toString()).claim("publicId", user.getPublicId().toString()).claim("role", user.getRole().name()).issuedAt(Date.from(now)).expiration(Date.from(now.plus(properties.getAccessTokenValidity()))).signWith(key, Jwts.SIG.HS256).compact(); }
    public Jws<Claims> parse(String token) { return Jwts.parser().verifyWith(key).build().parseSignedClaims(token); }
    public long getAccessTokenExpiresInSeconds() { return properties.getAccessTokenValidity().toSeconds(); }
}
