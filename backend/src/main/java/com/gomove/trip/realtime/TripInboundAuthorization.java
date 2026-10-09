package com.gomove.trip.realtime;

import com.gomove.auth.domain.UserRole;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.trip.infrastructure.TripStore;
import io.jsonwebtoken.Claims;
import org.springframework.messaging.Message;
import org.springframework.messaging.MessageChannel;
import org.springframework.messaging.simp.stomp.StompCommand;
import org.springframework.messaging.simp.stomp.StompHeaderAccessor;
import org.springframework.messaging.support.ChannelInterceptor;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.stereotype.Component;

import java.time.Clock;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

@Component
public class TripInboundAuthorization implements ChannelInterceptor {
    private static final Pattern TOPIC = Pattern.compile("^/topic/ride/([0-9a-fA-F-]{36})$");
    private static final Pattern LOCATION = Pattern.compile("^/app/ride/([0-9a-fA-F-]{36})/location$");
    private final JwtTokenProvider jwt;
    private final TripStore trips;
    private final TripSessionRegistry sessions;
    private final Clock clock;

    public TripInboundAuthorization(JwtTokenProvider jwt, TripStore trips,
                                    TripSessionRegistry sessions, Clock clock) {
        this.jwt = jwt;
        this.trips = trips;
        this.sessions = sessions;
        this.clock = clock;
    }

    @Override
    public Message<?> preSend(Message<?> message, MessageChannel channel) {
        StompHeaderAccessor accessor = StompHeaderAccessor.getAccessor(message, StompHeaderAccessor.class);
        if (accessor == null || accessor.getCommand() == null) return message;
        StompCommand command = accessor.getCommand();
        if (command == StompCommand.CONNECT) {
            var authentication = authenticate(accessor.getFirstNativeHeader("Authorization"));
            if (!sessions.register(accessor.getSessionId(), (Instant) authentication.getDetails())) throw denied();
            accessor.setUser(authentication);
            return message;
        }
        if (command == StompCommand.DISCONNECT) {
            sessions.remove(accessor.getSessionId());
            return message;
        }
        if (command == StompCommand.UNSUBSCRIBE) return message;
        if (!(accessor.getUser() instanceof UsernamePasswordAuthenticationToken authentication)
                || !(authentication.getPrincipal() instanceof CustomUserPrincipal user)
                || !(authentication.getDetails() instanceof Instant expiry)
                || !clock.instant().isBefore(expiry)
                || !sessions.isCurrent(accessor.getSessionId())) {
            throw denied();
        }
        String destination = accessor.getDestination();
        if (command == StompCommand.SUBSCRIBE) {
            UUID bookingId = bookingId(TOPIC, destination);
            if (trips.tracking(bookingId, user.publicId(), user.role()).isEmpty()) throw denied();
        } else if (command == StompCommand.SEND) {
            // In particular, a client cannot SEND to /topic/** or arbitrary broker destinations.
            UUID bookingId = bookingId(LOCATION, destination);
            if (user.role() != UserRole.DRIVER || !trips.mayTrack(bookingId, user.publicId())) throw denied();
        }
        return message;
    }

    private UsernamePasswordAuthenticationToken authenticate(String header) {
        if (header == null || !header.startsWith("Bearer ") || header.length() <= 7) throw denied();
        try {
            Claims claims = jwt.parse(header.substring(7)).getPayload();
            UUID publicId = UUID.fromString(claims.get("publicId", String.class));
            UserRole role = UserRole.valueOf(claims.get("role", String.class));
            if (!publicId.toString().equals(claims.getSubject())) throw denied();
            var principal = new CustomUserPrincipal(publicId, role);
            var authentication = new UsernamePasswordAuthenticationToken(principal, null,
                    List.of(new SimpleGrantedAuthority("ROLE_" + role.name())));
            authentication.setDetails(claims.getExpiration().toInstant());
            return authentication;
        } catch (RuntimeException ex) {
            throw denied();
        }
    }

    private UUID bookingId(Pattern pattern, String destination) {
        Matcher match = pattern.matcher(destination == null ? "" : destination);
        if (!match.matches()) throw denied();
        try { return UUID.fromString(match.group(1)); }
        catch (IllegalArgumentException ex) { throw denied(); }
    }

    private AccessDeniedException denied() { return new AccessDeniedException("STOMP destination is not authorized"); }
}
