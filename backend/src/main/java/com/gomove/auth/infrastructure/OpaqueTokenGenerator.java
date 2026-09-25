package com.gomove.auth.infrastructure;
import org.springframework.stereotype.Component;
import java.security.*;
import java.util.*;
@Component
public class OpaqueTokenGenerator {
    private final SecureRandom secureRandom = new SecureRandom();
    public String generate() { byte[] bytes=new byte[32]; secureRandom.nextBytes(bytes); return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes); }
    public String sha256(String token) { try { byte[] digest=MessageDigest.getInstance("SHA-256").digest(token.getBytes(java.nio.charset.StandardCharsets.UTF_8)); return HexFormat.of().formatHex(digest); } catch (NoSuchAlgorithmException ex) { throw new IllegalStateException(ex); } }
}
