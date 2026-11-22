package com.gomove.dispatch;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.auth.domain.*;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.booking.domain.*;
import com.gomove.booking.service.BookingApplicationService;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.dispatch.service.DispatchProperties;
import com.gomove.dispatch.service.DispatchWorker;
import com.gomove.driver.domain.*;
import com.gomove.pricing.domain.*;
import com.gomove.pricing.engine.PricingEngine;
import com.gomove.vehicle.domain.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.ApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.core.env.Environment;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.config.ScheduledTaskHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.sql.Timestamp;
import java.time.*;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
        "server.address=127.0.0.1",
        "gomove.dispatch.enabled=true", // The normal test profile disables the real worker.
        "gomove.dispatch.poll-interval-ms=100",
        "gomove.dispatch.reputation-tie-break-enabled=true",
        "gomove.dispatch.near-equal-meters=50"
})
@Import(DispatchReputationRuntimeE2ETest.ClockConfiguration.class)
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
class DispatchReputationRuntimeE2ETest extends BaseIntegrationTest {
    private static final Instant NOW = Instant.parse("2030-01-01T01:00:00Z");
    private static final double LAT = 21.0287;
    private static final double LON = 105.8524;
    private static final Set<Integer> RESERVED_PORTS = Set.of(
            5000, 5432, 15432, 15433, 15434, 18080, 18081, 18082, 18083, 18085);

    @LocalServerPort int port;
    @Autowired ApplicationContext context;
    @Autowired Environment environment;
    @Autowired DispatchProperties properties;
    @Autowired JdbcTemplate jdbc;
    @Autowired DataSource dataSource;
    @Autowired UserRepository users;
    @Autowired DriverRepository drivers;
    @Autowired VehicleRepository vehicles;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired BookingApplicationService bookingService;
    @Autowired PricingEngine pricing;
    @Autowired JwtTokenProvider jwt;
    @Autowired ObjectMapper mapper;
    @Autowired PlatformTransactionManager transactionManager;

    @Test
    @Timeout(45)
    void e2eDispatch01SchedulerOffersOnlyHigherReputationDriverThroughRealHttp() throws Exception {
        assertThat(properties.isReputationTieBreakEnabled()).isTrue();
        assertThat(properties.getNearEqualMeters()).isEqualTo(50);
        assertThat(environment.getProperty("gomove.dispatch.enabled", Boolean.class)).isTrue();
        assertThat(context.getBean(DispatchWorker.class)).isNotNull();
        // Spring decorates scheduled Runnables; inspect registration, not the wrapper's concrete type.
        var scheduledTasks = context.getBean(ScheduledTaskHolder.class).getScheduledTasks();
        assertThat(scheduledTasks).isNotEmpty();
        assertThat(port).isPositive().isNotIn(RESERVED_PORTS);
        assertThat(postgres.getMappedPort(5432)).isPositive().isNotIn(RESERVED_PORTS);
        assertThat(postgres.isShouldBeReused()).isFalse();
        var container = postgres.getContainerInfo();
        assertThat(container.getHostConfig().getBinds()).isNullOrEmpty();
        assertThat(container.getHostConfig().getVolumesFrom()).isNullOrEmpty();
        String jdbcFingerprint;
        try (var connection = dataSource.getConnection()) {
            String url = connection.getMetaData().getURL();
            assertThat(url).contains(":" + postgres.getMappedPort(5432) + "/" + postgres.getDatabaseName());
            jdbcFingerprint = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(url.getBytes(StandardCharsets.UTF_8)));
        }
        assertThat(jdbc.queryForObject("SELECT current_database()", String.class)).isEqualTo(postgres.getDatabaseName());
        assertThat(jdbc.queryForObject("SELECT version FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 1",
                String.class)).isEqualTo("19");

        // A single transaction hides intermediate REQUESTED rating fixtures from the live scheduler.
        Fixture fixture = new TransactionTemplate(transactionManager).execute(status -> seed());
        assertThat(fixture).isNotNull();
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM drivers d JOIN vehicles v ON v.driver_id=d.id AND v.is_active
                JOIN driver_locations dl ON dl.driver_id=d.id
                WHERE d.approval_status='APPROVED' AND d.operating_status='ONLINE'
                  AND v.vehicle_type='MOTORBIKE' AND dl.updated_at >= ?
                  AND NOT EXISTS (SELECT 1 FROM bookings b WHERE b.assigned_driver_id=d.id AND b.driver_released_at IS NULL)
                  AND NOT EXISTS (SELECT 1 FROM booking_driver_offers o WHERE o.driver_id=d.id AND o.status='PENDING')
                """, Integer.class, Timestamp.from(NOW.minusSeconds(30)))).isEqualTo(2);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM booking_driver_offers", Integer.class)).isZero();
        double distanceA = distance(fixture.driverA());
        double distanceB = distance(fixture.driverB());
        assertThat(distanceA).isBetween(499.0, 501.0);
        assertThat(distanceB).isBetween(519.0, 521.0);
        assertThat(distanceB - distanceA).isGreaterThan(0).isLessThanOrEqualTo(50);
        BigDecimal scoreA = score(fixture.driverA());
        BigDecimal scoreB = score(fixture.driverB());
        assertThat(scoreB).isGreaterThan(scoreA);

        try (HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build()) {
            String bookingJson = mapper.writeValueAsString(Map.of("quotePublicId", fixture.quote().getPublicId()));
            // Tokens are generated with the real provider and stay in memory. No MockMvc/security bypass.
            String customerToken = jwt.createAccessToken(fixture.customer());
            String driverAToken = jwt.createAccessToken(fixture.driverA().getUser());
            String driverBToken = jwt.createAccessToken(fixture.driverB().getUser());
            assertThat(send(http, "POST", "/api/v1/bookings", null, bookingJson).statusCode()).isEqualTo(401);
            var created = send(http, "POST", "/api/v1/bookings", customerToken, bookingJson);
            assertThat(created.statusCode()).isEqualTo(201);
            UUID bookingId = UUID.fromString(mapper.readTree(created.body()).path("data").path("bookingPublicId").asText());

            // Only the real @Scheduled worker/coordinator can create the offer in this test.
            await().atMost(Duration.ofSeconds(10)).pollInterval(Duration.ofMillis(100)).untilAsserted(() -> {
                JsonNode active = activeOffers(http, driverBToken);
                assertThat(active.size()).isEqualTo(1);
                assertThat(active.get(0).path("bookingPublicId").asText()).isEqualTo(bookingId.toString());
            });
            JsonNode winner = activeOffers(http, driverBToken).get(0);
            assertThat(activeOffers(http, driverAToken).size()).isZero();
            UUID offerId = UUID.fromString(winner.path("offerPublicId").asText());
            Instant offeredAt = Instant.parse(winner.path("offeredAt").asText());
            Instant expiresAt = Instant.parse(winner.path("expiresAt").asText());
            assertThat(Duration.between(offeredAt, expiresAt)).isEqualTo(Duration.ofSeconds(15));
            var fetched = send(http, "GET", "/api/v1/bookings/" + bookingId, customerToken, null);
            assertThat(fetched.statusCode()).isEqualTo(200);
            JsonNode booking = mapper.readTree(fetched.body()).path("data");
            assertThat(booking.path("status").asText()).isEqualTo("SEARCHING_DRIVER");
            assertThat(booking.hasNonNull("driverPublicId")).isFalse();

            Map<String, Object> persisted = jdbc.queryForMap("""
                    SELECT o.public_id, o.driver_id, o.status, o.offered_at, o.expires_at, b.status AS booking_status,
                           b.assigned_driver_id, b.assigned_vehicle_id
                    FROM booking_driver_offers o JOIN bookings b ON b.id=o.booking_id WHERE b.public_id=?
                    """, bookingId);
            assertThat(persisted.get("public_id")).isEqualTo(offerId);
            assertThat(((Number) persisted.get("driver_id")).longValue()).isEqualTo(fixture.driverB().getId());
            assertThat(persisted.get("status")).isEqualTo("PENDING");
            assertThat(persisted.get("booking_status")).isEqualTo("SEARCHING_DRIVER");
            assertThat(persisted.get("assigned_driver_id")).isNull();
            assertThat(persisted.get("assigned_vehicle_id")).isNull();
            assertThat(((Timestamp) persisted.get("offered_at")).toInstant()).isEqualTo(offeredAt);
            assertThat(((Timestamp) persisted.get("expires_at")).toInstant()).isEqualTo(expiresAt);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM booking_driver_offers", Integer.class)).isEqualTo(1);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM booking_driver_offers WHERE driver_id=?",
                    Integer.class, fixture.driverA().getId())).isZero();
            assertThat(jdbc.queryForObject("SELECT count(*) FROM booking_driver_offers WHERE status='PENDING'",
                    Integer.class)).isEqualTo(1);

            Map<String, Object> evidence = new LinkedHashMap<>();
            evidence.put("scenario", "E2E-Dispatch-01");
            evidence.put("measuredAt", Instant.now().toString());
            evidence.put("clock", NOW.toString());
            evidence.put("httpPort", port);
            evidence.put("postgresPort", postgres.getMappedPort(5432));
            evidence.put("containerId", postgres.getContainerId());
            evidence.put("databaseUrlSha256", jdbcFingerprint);
            evidence.put("database", postgres.getDatabaseName());
            evidence.put("containerReuse", postgres.isShouldBeReused());
            evidence.put("hostBinds", 0);
            evidence.put("volumesFrom", 0);
            evidence.put("flywayVersion", "19");
            evidence.put("effectiveFlag", properties.isReputationTieBreakEnabled());
            evidence.put("effectiveBandMeters", properties.getNearEqualMeters());
            evidence.put("scheduledTasks", scheduledTasks.stream()
                    .map(task -> task.getTask().getRunnable().toString()).toList());
            evidence.put("driverAId", fixture.driverA().getPublicId());
            evidence.put("driverBId", fixture.driverB().getPublicId());
            evidence.put("distanceAMeters", distanceA);
            evidence.put("distanceBMeters", distanceB);
            evidence.put("scoreA", scoreA);
            evidence.put("scoreB", scoreB);
            evidence.put("ratingAStars", 3);
            evidence.put("ratingBStars", 5);
            evidence.put("ratingCountEach", 1);
            evidence.put("bookingId", bookingId);
            evidence.put("offerId", offerId);
            evidence.put("winnerDriverId", fixture.driverB().getPublicId());
            evidence.put("totalOffers", 1);
            evidence.put("pendingOffers", 1);
            evidence.put("driverAOffers", 0);
            evidence.put("offerStatus", persisted.get("status"));
            evidence.put("bookingStatus", persisted.get("booking_status"));
            evidence.put("offeredAt", offeredAt.toString());
            evidence.put("expiresAt", expiresAt.toString());
            evidence.put("leaseSeconds", Duration.between(offeredAt, expiresAt).toSeconds());
            Files.createDirectories(Path.of("target"));
            Files.writeString(Path.of("target/e2e-dispatch-01-runtime.json"),
                    mapper.writerWithDefaultPrettyPrinter().writeValueAsString(evidence));
        }
    }

    private Fixture seed() {
        User customer = user(UserRole.CUSTOMER);
        Driver a = driver(500);
        Driver b = driver(520);
        rating(customer, a, 3);
        rating(customer, b, 5);
        return new Fixture(customer, a, b, quote(customer));
    }

    private User user(UserRole role) {
        User user = new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "runtime-" + UUID.randomUUID() + "@example.test", "hash", "Runtime E2E Fixture");
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private Driver driver(double meters) {
        Driver driver = new Driver(user(UserRole.DRIVER), "RUNTIME-" + UUID.randomUUID());
        driver.setApprovalStatus(DriverApprovalStatus.APPROVED);
        driver.setOperatingStatus(DriverOperatingStatus.ONLINE);
        driver = drivers.saveAndFlush(driver);
        Vehicle vehicle = new Vehicle(driver, "E-" + UUID.randomUUID().toString().substring(0, 12),
                VehicleType.MOTORBIKE, "Test", "Test", "White");
        vehicle.setActive(true);
        vehicles.saveAndFlush(vehicle);
        jdbc.update("""
                INSERT INTO driver_locations(driver_id,current_location,updated_at,version)
                VALUES (?,ST_Project(ST_SetSRID(ST_MakePoint(?,?),4326)::geography,?,0),?,0)
                """, driver.getId(), LON, LAT, meters, Timestamp.from(NOW));
        return driver;
    }

    private Quote quote(User customer) {
        RouteEstimate route = new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "TEST_ROUTER");
        return quotes.saveAndFlush(new Quote(customer,
                new GeoCoordinate(BigDecimal.valueOf(LAT), BigDecimal.valueOf(LON)),
                new GeoCoordinate(new BigDecimal("21.0245"), new BigDecimal("105.8576")),
                VehicleType.MOTORBIKE, route, pricing.calculate(VehicleType.MOTORBIKE, route), NOW));
    }

    private void rating(User customer, Driver driver, int stars) {
        Quote quote = quote(customer);
        bookingService.create(customer.getPublicId(), UserRole.CUSTOMER, quote.getPublicId(), UUID.randomUUID().toString());
        Booking booking = bookings.findOwned(jdbc.queryForObject("SELECT public_id FROM bookings WHERE quote_id=?",
                UUID.class, quote.getId()), customer.getPublicId()).orElseThrow();
        Long vehicle = jdbc.queryForObject("SELECT id FROM vehicles WHERE driver_id=? AND is_active", Long.class, driver.getId());
        jdbc.update("""
                UPDATE bookings SET status='COMPLETED', assigned_driver_id=?, assigned_vehicle_id=?,
                    driver_accepted_at=?, driver_arrived_at=?, passenger_onboard_at=?, trip_started_at=?,
                    trip_completed_at=?, driver_released_at=?, version=version+1 WHERE id=?
                """, driver.getId(), vehicle, Timestamp.from(NOW), Timestamp.from(NOW), Timestamp.from(NOW),
                Timestamp.from(NOW), Timestamp.from(NOW), Timestamp.from(NOW), booking.getId());
        jdbc.update("INSERT INTO trip_ratings(public_id,booking_id,customer_id,driver_id,stars) VALUES (?,?,?,?,?)",
                UUID.randomUUID(), booking.getId(), customer.getId(), driver.getId(), stars);
    }

    private double distance(Driver driver) {
        return jdbc.queryForObject("""
                SELECT ST_Distance(current_location,ST_SetSRID(ST_MakePoint(?,?),4326)::geography)
                FROM driver_locations WHERE driver_id=?
                """, Double.class, LON, LAT, driver.getId());
    }

    private BigDecimal score(Driver driver) {
        assertThat(jdbc.queryForObject("SELECT count(*) FROM trip_ratings WHERE driver_id=?", Integer.class,
                driver.getId())).isEqualTo(1);
        return jdbc.queryForObject("SELECT (sum(stars)::numeric+10*4.0)/(count(*)+10) FROM trip_ratings WHERE driver_id=?",
                BigDecimal.class, driver.getId());
    }

    private HttpResponse<String> send(HttpClient http, String method, String path, String token, String body) throws Exception {
        var request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + path)).timeout(Duration.ofSeconds(3));
        if (token != null) request.header("Authorization", "Bearer " + token);
        if (body == null) request.GET();
        else request.header("Content-Type", "application/json").header("Idempotency-Key", UUID.randomUUID().toString())
                .method(method, HttpRequest.BodyPublishers.ofString(body));
        return http.send(request.build(), HttpResponse.BodyHandlers.ofString());
    }

    private JsonNode activeOffers(HttpClient http, String token) throws Exception {
        var response = send(http, "GET", "/api/v1/drivers/me/offers/active", token, null);
        assertThat(response.statusCode()).isEqualTo(200);
        JsonNode data = mapper.readTree(response.body()).path("data");
        assertThat(data.isArray()).isTrue();
        return data;
    }

    private record Fixture(User customer, Driver driverA, Driver driverB, Quote quote) {}

    @TestConfiguration static class ClockConfiguration {
        @Bean @Primary Clock runtimeDispatchClock() { return Clock.fixed(NOW, ZoneOffset.UTC); }
    }
}
