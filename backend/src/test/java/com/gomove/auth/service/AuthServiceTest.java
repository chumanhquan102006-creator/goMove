package com.gomove.auth.service;
import com.gomove.auth.api.*;
import com.gomove.auth.domain.*;
import com.gomove.auth.infrastructure.*;
import com.gomove.common.exception.BaseException;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.*;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.crypto.password.PasswordEncoder;
import java.time.Duration;
import java.util.Optional;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
@ExtendWith(MockitoExtension.class)
class AuthServiceTest {
    @Mock UserRepository users; @Mock RefreshTokenRepository refreshTokens; @Mock PasswordEncoder encoder; @Mock JwtTokenProvider jwt; @Mock OpaqueTokenGenerator opaque;
    AuthProperties props; AuthService service;
    @BeforeEach void setup() { props=new AuthProperties();props.setMaxFailedLoginAttempts(5);props.setLockDuration(Duration.ofMinutes(15));service=new AuthService(users,refreshTokens,encoder,jwt,opaque,props); }
    @Test void registerSuccessAlwaysCreatesCustomer() { when(users.existsByPhone("0900")).thenReturn(false);when(encoder.encode("password1")).thenReturn("bcrypt");when(users.save(any(User.class))).thenAnswer(i -> i.getArgument(0)); UserResponse response=service.register(new RegisterRequest("0900",null,"password1","Name")); assertThat(response.role()).isEqualTo("CUSTOMER"); }
    @Test void duplicatePhoneIsConflict() { when(users.existsByPhone("0900")).thenReturn(true); assertThatThrownBy(() -> service.register(new RegisterRequest("0900",null,"password1","Name"))).isInstanceOf(BaseException.class).extracting("status").isEqualTo(org.springframework.http.HttpStatus.CONFLICT); }
    @Test void fifthInvalidLoginLocksAccount() { User user=new User("0900",null,"bcrypt","Name");when(users.findByIdentifierForUpdate("0900")).thenReturn(Optional.of(user));when(encoder.matches("wrong","bcrypt")).thenReturn(false); for(int i=0;i<5;i++) assertThatThrownBy(() -> service.login(new LoginRequest("0900","wrong"))).isInstanceOf(BaseException.class); assertThat(user.getStatus()).isEqualTo(UserStatus.LOCKED); }
    @Test void disabledAccountRejectsLogin() { User user=new User("0900",null,"bcrypt","Name");user.setStatus(UserStatus.DISABLED);when(users.findByIdentifierForUpdate("0900")).thenReturn(Optional.of(user)); assertThatThrownBy(() -> service.login(new LoginRequest("0900","password1"))).isInstanceOf(BaseException.class); verify(encoder,never()).matches(any(),any()); }
}
