package com.gomove.auth.infrastructure;
import com.gomove.auth.domain.*;
import org.junit.jupiter.api.Test;
import java.lang.reflect.Field;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
class JwtTokenProviderTest {
    @Test void createsExplicitHs256TokenWithPublicIdentityClaims() throws Exception {
        AuthProperties properties=new AuthProperties(); properties.setJwtSecret("test-only-secret-at-least-thirty-two-bytes-long");
        User user=new User("0900000000",null,"hash","Test"); Field field=Class.forName("com.gomove.common.persistence.BaseEntity").getDeclaredField("publicId"); field.setAccessible(true); UUID id=UUID.randomUUID(); field.set(user,id);
        String token=new JwtTokenProvider(properties).createAccessToken(user);
        String header=new String(java.util.Base64.getUrlDecoder().decode(token.split("\\.")[0]), java.nio.charset.StandardCharsets.UTF_8);
        assertThat(header).contains("\"alg\":\"HS256\"");
        assertThat(new JwtTokenProvider(properties).parse(token).getPayload().get("publicId",String.class)).isEqualTo(id.toString());
        assertThatThrownBy(() -> new JwtTokenProvider(properties).parse(token+"x")).isInstanceOf(Exception.class);
        assertThatThrownBy(() -> new JwtTokenProvider(properties).parse("not.a.jwt")).isInstanceOf(Exception.class);
    }
}
