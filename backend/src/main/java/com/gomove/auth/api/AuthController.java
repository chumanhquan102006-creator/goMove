package com.gomove.auth.api;
import com.gomove.auth.service.AuthService;
import com.gomove.common.api.ApiResponse;
import com.gomove.common.security.CustomUserPrincipal;
import jakarta.validation.Valid;
import org.springframework.http.*;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.*;
@RestController @RequestMapping("/api/v1/auth")
public class AuthController {
    private final AuthService service; public AuthController(AuthService service) { this.service=service; }
    @PostMapping("/register") ResponseEntity<ApiResponse<UserResponse>> register(@Valid @RequestBody RegisterRequest request) { return ResponseEntity.status(HttpStatus.CREATED).body(ApiResponse.success("REGISTERED","Registration successful",service.register(request))); }
    @PostMapping("/login") ApiResponse<AuthResponse> login(@Valid @RequestBody LoginRequest request) { return ApiResponse.success("LOGIN_SUCCESS","Login successful",service.login(request)); }
    @PostMapping("/refresh") ApiResponse<AuthResponse> refresh(@Valid @RequestBody RefreshTokenRequest request) { return ApiResponse.success("TOKEN_REFRESHED","Token refreshed",service.refresh(request.refreshToken())); }
    @PostMapping("/logout") ResponseEntity<ApiResponse<Void>> logout(@Valid @RequestBody RefreshTokenRequest request) { service.logout(request.refreshToken()); return ResponseEntity.ok(ApiResponse.success("LOGGED_OUT","Logout successful",null)); }
    @GetMapping("/me") ApiResponse<UserResponse> me(@AuthenticationPrincipal CustomUserPrincipal principal) { return ApiResponse.success("OK","Current user",service.me(principal.publicId())); }
}
