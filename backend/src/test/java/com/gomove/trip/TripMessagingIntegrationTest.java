package com.gomove.trip;

import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.auth.domain.UserRole;
import com.gomove.auth.infrastructure.AuthProperties;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.booking.domain.Booking;
import com.gomove.booking.domain.BookingRepository;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.driver.domain.Driver;
import com.gomove.driver.domain.DriverApprovalStatus;
import com.gomove.driver.domain.DriverOperatingStatus;
import com.gomove.driver.domain.DriverRepository;
import com.gomove.location.api.UpdateDriverLocationRequest;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.Quote;
import com.gomove.pricing.domain.QuoteRepository;
import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.engine.PricingEngine;
import com.gomove.trip.service.TripAction;
import com.gomove.trip.service.TripApplicationService;
import com.gomove.vehicle.domain.Vehicle;
import com.gomove.vehicle.domain.VehicleRepository;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.messaging.Message;
import org.springframework.messaging.MessageChannel;
import org.springframework.messaging.MessageDeliveryException;
import org.springframework.messaging.simp.stomp.StompCommand;
import org.springframework.messaging.simp.stomp.StompHeaderAccessor;
import org.springframework.messaging.simp.SimpMessageType;
import org.springframework.messaging.simp.SimpMessageHeaderAccessor;
import org.springframework.messaging.simp.broker.SimpleBrokerMessageHandler;
import org.springframework.messaging.support.ChannelInterceptor;
import org.springframework.messaging.support.MessageBuilder;
import org.springframework.messaging.support.ExecutorSubscribableChannel;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.transaction.support.TransactionTemplate;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.Principal;
import java.sql.Timestamp;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.Date;
import java.util.UUID;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@Import(TripMessagingIntegrationTest.ClockConfiguration.class)
class TripMessagingIntegrationTest extends BaseIntegrationTest {
    @Autowired @Qualifier("clientInboundChannel") MessageChannel inbound;
    @Autowired @Qualifier("clientOutboundChannel") ExecutorSubscribableChannel outbound;
    @Autowired UserRepository users;
    @Autowired DriverRepository drivers;
    @Autowired VehicleRepository vehicles;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired PricingEngine pricing;
    @Autowired JwtTokenProvider jwt;
    @Autowired AuthProperties authProperties;
    @Autowired MutableClock clock;
    @Autowired JdbcTemplate jdbc;
    @Autowired TripApplicationService trips;
    @Autowired TransactionTemplate transactions;
    @Autowired SimpleBrokerMessageHandler broker;

    private final BlockingQueue<Message<?>> delivered = new LinkedBlockingQueue<>();
    private final ChannelInterceptor capture = new ChannelInterceptor() {
        @Override public Message<?> preSend(Message<?> message, MessageChannel channel) {
            delivered.add(message);
            return message;
        }
    };

    @BeforeEach void captureOutbound() { clock.set(Instant.now()); outbound.addInterceptor(capture); }
    @AfterEach void stopCapture() { outbound.removeInterceptor(capture); delivered.clear(); }

    @Test
    void connectSubscribeAndSendAreAuthorizedByRealInboundChannel() throws Exception {
        Ride ride = ride();
        Ride foreign = ride();
        User stranger = user(UserRole.CUSTOMER);
        Driver unrelated = driver();
        assertThatThrownBy(() -> connect(null)).isInstanceOf(MessageDeliveryException.class)
                .hasCauseInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> connect("Bearer invalid.jwt.token"))
                .isInstanceOf(MessageDeliveryException.class).hasCauseInstanceOf(AccessDeniedException.class);

        Client customer = connect(bearer(ride.customer()));
        Client driver = connect(bearer(ride.driver().getUser()));
        Client foreignCustomer = connect(bearer(foreign.customer()));
        Client strangerClient = connect(bearer(stranger));
        Client unrelatedClient = connect(bearer(unrelated.getUser()));
        subscribe(customer, ride.booking().getPublicId());
        subscribe(driver, ride.booking().getPublicId());
        assertThatThrownBy(() -> subscribe(foreignCustomer, ride.booking().getPublicId()))
                .isInstanceOf(MessageDeliveryException.class).hasCauseInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> subscribe(strangerClient, ride.booking().getPublicId()))
                .isInstanceOf(MessageDeliveryException.class).hasCauseInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> subscribe(unrelatedClient, ride.booking().getPublicId()))
                .isInstanceOf(MessageDeliveryException.class).hasCauseInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> send(customer, "/app/ride/" + ride.booking().getPublicId() + "/location", "{}"))
                .isInstanceOf(MessageDeliveryException.class).hasCauseInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> send(unrelatedClient,
                "/app/ride/" + ride.booking().getPublicId() + "/location", "{}"))
                .isInstanceOf(MessageDeliveryException.class).hasCauseInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> send(driver, "/topic/ride/" + ride.booking().getPublicId(), "{}"))
                .isInstanceOf(MessageDeliveryException.class).hasCauseInstanceOf(AccessDeniedException.class);

        waitForSubscription(customer, ride.booking().getPublicId());
        waitForSubscription(driver, ride.booking().getPublicId());
        delivered.clear();
        send(driver, "/app/ride/" + ride.booking().getPublicId() + "/location",
                "{\"latitude\":21.0287,\"longitude\":105.8524,\"accuracy\":8.5,\"bearing\":120.0}");
        String event = awaitEvent("DRIVER_LOCATION_UPDATED");
        assertThat(event).contains(ride.booking().getPublicId().toString(), "21.0287", "105.8524");
        assertThat(jdbc.queryForObject("SELECT ST_X(current_location::geometry) FROM driver_locations WHERE driver_id=?",
                Double.class, ride.driver().getId())).isEqualTo(105.8524);
        for (TripAction action : TripAction.values()) {
            trips.transition(ride.booking().getPublicId(), ride.driver().getUser().getPublicId(),
                    UserRole.DRIVER, action);
        }
        assertThat(awaitEvent("TRIP_STATUS_CHANGED")).contains(ride.booking().getPublicId().toString());
        assertThatThrownBy(() -> send(driver,
                "/app/ride/" + ride.booking().getPublicId() + "/location",
                "{\"latitude\":21.0,\"longitude\":105.0}"))
                .isInstanceOf(MessageDeliveryException.class).hasCauseInstanceOf(AccessDeniedException.class);
    }

    @Test
    void eventsFollowCommitAndRollbackCannotBroadcast() throws Exception {
        Ride ride = ride();
        Client customer = connect(bearer(ride.customer()));
        subscribe(customer, ride.booking().getPublicId());
        waitForSubscription(customer, ride.booking().getPublicId());
        delivered.clear();

        assertThatThrownBy(() -> transactions.executeWithoutResult(status -> {
            trips.updateRideLocation(ride.booking().getPublicId(), ride.driver().getUser().getPublicId(),
                    UserRole.DRIVER, new UpdateDriverLocationRequest(21.02, 105.85, null, null));
            assertThat(locationExists(ride.driver())).isTrue();
            assertThat(delivered).noneMatch(this::isRideEvent);
            throw new IllegalStateException("rollback test");
        })).isInstanceOf(IllegalStateException.class);
        assertThat(locationExists(ride.driver())).isFalse();
        assertThat(delivered).noneMatch(this::isRideEvent);

        transactions.executeWithoutResult(status -> {
            trips.updateRideLocation(ride.booking().getPublicId(), ride.driver().getUser().getPublicId(),
                    UserRole.DRIVER, new UpdateDriverLocationRequest(21.0287, 105.8524, null, null));
            assertThat(delivered).noneMatch(this::isRideEvent);
        });
        assertThat(awaitEvent("DRIVER_LOCATION_UPDATED")).contains("21.0287");
        delivered.clear();
        transactions.executeWithoutResult(status -> {
            trips.transition(ride.booking().getPublicId(), ride.driver().getUser().getPublicId(),
                    UserRole.DRIVER, TripAction.ARRIVE);
            assertThat(delivered).noneMatch(this::isRideEvent);
        });
        assertThat(awaitEvent("TRIP_STATUS_CHANGED")).contains("DRIVER_ARRIVED");
    }

    @Test
    void expiredSubscriptionIsDeniedOutboundAndFreshJwtCanReconnect() throws Exception {
        Ride ride = ride();
        Client old = connect(bearer(ride.customer()));
        subscribe(old, ride.booking().getPublicId());
        waitForSubscription(old, ride.booking().getPublicId());
        delivered.clear();
        trips.transition(ride.booking().getPublicId(), ride.driver().getUser().getPublicId(),
                UserRole.DRIVER, TripAction.ARRIVE);
        assertThat(awaitEventForSession("DRIVER_ARRIVED", old.sessionId())).contains("TRIP_STATUS_CHANGED");

        Instant expiry = (Instant) ((UsernamePasswordAuthenticationToken) old.principal()).getDetails();
        clock.set(expiry); // Exactly at expiry is already unauthorized; no real-time waiting.
        assertThat(isSubscribed(old, ride.booking().getPublicId())).isTrue();
        CountDownLatch brokerAttempted = new CountDownLatch(1);
        ChannelInterceptor beforeExpiryFilter = new ChannelInterceptor() {
            @Override public Message<?> preSend(Message<?> message, MessageChannel channel) {
                if (isRideEvent(message) && old.sessionId().equals(
                        SimpMessageHeaderAccessor.getSessionId(message.getHeaders()))) {
                    brokerAttempted.countDown();
                }
                return message;
            }
        };
        outbound.addInterceptor(0, beforeExpiryFilter);
        try {
            delivered.clear();
            trips.transition(ride.booking().getPublicId(), ride.driver().getUser().getPublicId(),
                    UserRole.DRIVER, TripAction.ONBOARD);
            assertThat(brokerAttempted.await(5, TimeUnit.SECONDS)).isTrue();
            assertThat(delivered).noneMatch(message -> isRideEvent(message)
                    && old.sessionId().equals(SimpMessageHeaderAccessor.getSessionId(message.getHeaders())));
        } finally {
            outbound.removeInterceptor(beforeExpiryFilter);
        }

        assertThatThrownBy(() -> subscribe(old, ride.booking().getPublicId()))
                .isInstanceOf(MessageDeliveryException.class).hasCauseInstanceOf(AccessDeniedException.class);
        Client refreshed = connect(bearerAt(ride.customer(), clock.instant()));
        subscribe(refreshed, ride.booking().getPublicId());
        waitForSubscription(refreshed, ride.booking().getPublicId());
        delivered.clear();
        trips.transition(ride.booking().getPublicId(), ride.driver().getUser().getPublicId(),
                UserRole.DRIVER, TripAction.START);
        assertThat(awaitEventForSession("IN_PROGRESS", refreshed.sessionId()))
                .contains(ride.booking().getPublicId().toString());
    }

    private Ride ride() {
        User customer = user(UserRole.CUSTOMER);
        RouteEstimate route = new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "TEST_ROUTER");
        Quote quote = quotes.saveAndFlush(new Quote(customer,
                new GeoCoordinate(new BigDecimal("21.0287"), new BigDecimal("105.8524")),
                new GeoCoordinate(new BigDecimal("21.0245"), new BigDecimal("105.8576")),
                VehicleType.MOTORBIKE, route, pricing.calculate(VehicleType.MOTORBIKE, route), Instant.now()));
        Booking booking = bookings.saveAndFlush(new Booking(customer, quote));
        Driver driver = driver();
        Vehicle vehicle = new Vehicle(driver, "MSG-" + UUID.randomUUID().toString().substring(0, 12),
                VehicleType.MOTORBIKE, "Test", "Test", "White");
        vehicle.setActive(true);
        vehicle = vehicles.saveAndFlush(vehicle);
        jdbc.update("""
                UPDATE bookings SET status='DRIVER_ACCEPTED', assigned_driver_id=?, assigned_vehicle_id=?,
                    driver_accepted_at=?, version=version+1 WHERE id=?
                """, driver.getId(), vehicle.getId(), Timestamp.from(Instant.now()), booking.getId());
        return new Ride(customer, driver, booking);
    }

    private User user(UserRole role) {
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "msg-" + UUID.randomUUID() + "@example.test", "hash", "Messaging Test");
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private Driver driver() {
        Driver driver = new Driver(user(UserRole.DRIVER), "MSG-" + UUID.randomUUID());
        driver.setApprovalStatus(DriverApprovalStatus.APPROVED);
        driver.setOperatingStatus(DriverOperatingStatus.BUSY);
        return drivers.saveAndFlush(driver);
    }

    private Client connect(String authorization) throws InterruptedException {
        String sessionId = UUID.randomUUID().toString();
        java.util.Map<String, Object> sessionAttributes = new java.util.concurrent.ConcurrentHashMap<>();
        StompHeaderAccessor header = StompHeaderAccessor.create(StompCommand.CONNECT);
        header.setSessionId(sessionId);
        header.setSessionAttributes(sessionAttributes);
        header.setLeaveMutable(true);
        if (authorization != null) header.addNativeHeader("Authorization", authorization);
        inbound.send(MessageBuilder.createMessage(new byte[0], header.getMessageHeaders()));
        assertThat(header.getUser()).isNotNull();
        waitForType(SimpMessageType.CONNECT_ACK);
        return new Client(sessionId, header.getUser(), sessionAttributes);
    }

    private void subscribe(Client client, UUID bookingId) {
        StompHeaderAccessor header = headers(StompCommand.SUBSCRIBE, client);
        header.setDestination("/topic/ride/" + bookingId);
        header.setSubscriptionId(UUID.randomUUID().toString());
        inbound.send(MessageBuilder.createMessage(new byte[0], header.getMessageHeaders()));
    }

    private void send(Client client, String destination, String json) {
        StompHeaderAccessor header = headers(StompCommand.SEND, client);
        header.setDestination(destination);
        header.setContentType(org.springframework.util.MimeTypeUtils.APPLICATION_JSON);
        inbound.send(MessageBuilder.createMessage(json.getBytes(StandardCharsets.UTF_8), header.getMessageHeaders()));
    }

    private StompHeaderAccessor headers(StompCommand command, Client client) {
        StompHeaderAccessor header = StompHeaderAccessor.create(command);
        header.setSessionId(client.sessionId());
        header.setSessionAttributes(client.sessionAttributes());
        header.setUser(client.principal());
        header.setLeaveMutable(true);
        return header;
    }

    private void waitForSubscription(Client client, UUID bookingId) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (System.nanoTime() < deadline) {
            if (isSubscribed(client, bookingId)) return;
            Thread.sleep(10);
        }
        throw new AssertionError("Subscription was not installed in the real broker");
    }

    private boolean isSubscribed(Client client, UUID bookingId) {
        SimpMessageHeaderAccessor header = SimpMessageHeaderAccessor.create(SimpMessageType.MESSAGE);
        header.setDestination("/topic/ride/" + bookingId);
        Message<byte[]> event = MessageBuilder.createMessage(new byte[0], header.getMessageHeaders());
        return broker.getSubscriptionRegistry().findSubscriptions(event).containsKey(client.sessionId());
    }

    private void waitForType(SimpMessageType type) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        java.util.List<Object> seen = new java.util.ArrayList<>();
        while (System.nanoTime() < deadline) {
            Message<?> message = delivered.poll(100, TimeUnit.MILLISECONDS);
            if (message != null) {
                Object actual = message.getHeaders().get("simpMessageType");
                seen.add(actual);
                if (actual == type) return;
            }
        }
        throw new AssertionError("STOMP frame not received: " + type + "; seen " + seen);
    }

    private String awaitEvent(String type) throws InterruptedException {
        return awaitEventForSession(type, null);
    }

    private String awaitEventForSession(String type, String sessionId) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (System.nanoTime() < deadline) {
            Message<?> message = delivered.poll(100, TimeUnit.MILLISECONDS);
            if (message != null && isRideEvent(message)
                    && (sessionId == null || sessionId.equals(
                        SimpMessageHeaderAccessor.getSessionId(message.getHeaders())))) {
                String body = new String((byte[]) message.getPayload(), StandardCharsets.UTF_8);
                if (body.contains(type)) return body;
            }
        }
        throw new AssertionError("Ride event not received: " + type);
    }

    private boolean isRideEvent(Message<?> message) {
        return message.getHeaders().get("simpMessageType") == SimpMessageType.MESSAGE;
    }

    private boolean locationExists(Driver driver) {
        return jdbc.queryForObject("SELECT EXISTS (SELECT 1 FROM driver_locations WHERE driver_id=?)",
                Boolean.class, driver.getId());
    }

    private String bearer(User user) { return "Bearer " + jwt.createAccessToken(user); }

    private String bearerAt(User user, Instant issuedAt) {
        var key = Keys.hmacShaKeyFor(authProperties.getJwtSecret().getBytes(StandardCharsets.UTF_8));
        String token = Jwts.builder().subject(user.getPublicId().toString())
                .claim("publicId", user.getPublicId().toString()).claim("role", user.getRole().name())
                .issuedAt(Date.from(issuedAt))
                .expiration(Date.from(issuedAt.plus(authProperties.getAccessTokenValidity())))
                .signWith(key, Jwts.SIG.HS256).compact();
        return "Bearer " + token;
    }

    private record Client(String sessionId, Principal principal, java.util.Map<String, Object> sessionAttributes) {}
    private record Ride(User customer, Driver driver, Booking booking) {}

    static class MutableClock extends Clock {
        private final AtomicReference<Instant> now = new AtomicReference<>(Instant.now());
        void set(Instant value) { now.set(value); }
        @Override public ZoneId getZone() { return ZoneOffset.UTC; }
        @Override public Clock withZone(ZoneId zone) { return Clock.fixed(now.get(), zone); }
        @Override public Instant instant() { return now.get(); }
    }

    @TestConfiguration
    static class ClockConfiguration {
        @Bean @Primary MutableClock tripSecurityTestClock() { return new MutableClock(); }
    }

}
