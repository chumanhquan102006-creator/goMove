package com.gomove.common.security;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.auth.domain.UserRole;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.common.api.ErrorResponse;
import io.jsonwebtoken.Claims;
import jakarta.servlet.*;
import jakarta.servlet.http.*;
import org.springframework.http.MediaType;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import java.io.IOException;
import java.util.*;
@Component
public class JwtAuthenticationFilter extends OncePerRequestFilter {
    private final JwtTokenProvider jwt; private final ObjectMapper mapper;
    public JwtAuthenticationFilter(JwtTokenProvider jwt, ObjectMapper mapper) { this.jwt=jwt;this.mapper=mapper; }
    @Override protected void doFilterInternal(HttpServletRequest request,HttpServletResponse response,FilterChain chain) throws ServletException,IOException {
        String header=request.getHeader("Authorization");
        if (header==null || header.isBlank()) { chain.doFilter(request,response); return; }
        if (!header.startsWith("Bearer ") || header.length()<=7) { unauthorized(request,response); return; }
        try {
            Claims claims=jwt.parse(header.substring(7)).getPayload(); UUID publicId=UUID.fromString(claims.get("publicId",String.class)); UserRole role=UserRole.valueOf(claims.get("role",String.class));
            if (!publicId.toString().equals(claims.getSubject())) throw new IllegalArgumentException("Subject mismatch");
            CustomUserPrincipal principal=new CustomUserPrincipal(publicId,role);
            SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(principal,null,List.of(new SimpleGrantedAuthority("ROLE_"+role.name()))));
            chain.doFilter(request,response);
        } catch (Exception ex) { SecurityContextHolder.clearContext(); unauthorized(request,response); }
    }
    private void unauthorized(HttpServletRequest request,HttpServletResponse response) throws IOException { response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);response.setContentType(MediaType.APPLICATION_JSON_VALUE);mapper.writeValue(response.getOutputStream(), ErrorResponse.of("UNAUTHORIZED","Unauthorized",request.getRequestURI(),Map.of())); }
}
