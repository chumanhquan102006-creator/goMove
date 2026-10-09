package com.gomove.booking;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.gomove.auth.domain.User;
import com.gomove.auth.domain.UserRepository;
import com.gomove.auth.domain.UserRole;
import com.gomove.auth.infrastructure.JwtTokenProvider;
import com.gomove.booking.domain.Booking;
import com.gomove.booking.domain.BookingRepository;
import com.gomove.booking.domain.BookingStatus;
import com.gomove.booking.service.BookingApplicationService;
import com.gomove.common.BaseIntegrationTest;
import com.gomove.common.exception.DomainException;
import com.gomove.pricing.domain.GeoCoordinate;
import com.gomove.pricing.domain.Quote;
import com.gomove.pricing.domain.QuoteRepository;
import com.gomove.pricing.domain.QuoteStatus;
import com.gomove.pricing.domain.RouteEstimate;
import com.gomove.pricing.engine.PricingEngine;
import com.gomove.pricing.engine.PricingProperties;
import com.gomove.vehicle.domain.VehicleType;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.locks.LockSupport;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@AutoConfigureMockMvc
@Import(BookingIntegrationTest.ClockConfiguration.class)
class BookingIntegrationTest extends BaseIntegrationTest {
    private static final String PATH = "/api/v1/bookings";
    private static final Instant FIXED = Instant.parse("2030-01-01T01:00:00Z");

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired UserRepository users;
    @Autowired QuoteRepository quotes;
    @Autowired BookingRepository bookings;
    @Autowired BookingApplicationService bookingService;
    @Autowired PricingEngine pricing;
    @Autowired PricingProperties pricingProperties;
    @Autowired JwtTokenProvider jwt;
    @Autowired JdbcTemplate jdbc;
    @Autowired DataSource dataSource;
    @Autowired MutableClock clock;

    @BeforeEach
    void resetClock() {
        clock.set(FIXED);
    }

    @Test
    void securityValidationOwnershipAndExactReplayAfterExpiry() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        User other = user(UserRole.CUSTOMER);
        User driver = user(UserRole.DRIVER);
        Quote quote = quote(customer);
        Quote otherQuote = quote(other);
        String key = UUID.randomUUID().toString();

        mvc.perform(post(PATH).contentType(MediaType.APPLICATION_JSON).content(request(quote)))
                .andExpect(status().isUnauthorized());
        mvc.perform(post(PATH).header("Authorization", bearer(driver))
                        .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON).content(request(quote)))
                .andExpect(status().isForbidden());
        mvc.perform(post(PATH).header("Authorization", bearer(customer))
                        .contentType(MediaType.APPLICATION_JSON).content(request(quote)))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.code").value("INVALID_IDEMPOTENCY_KEY"));
        mvc.perform(post(PATH).header("Authorization", bearer(customer))
                        .header("Idempotency-Key", "bad key")
                        .contentType(MediaType.APPLICATION_JSON).content(request(quote)))
                .andExpect(status().isBadRequest());
        mvc.perform(post(PATH).header("Authorization", bearer(customer))
                        .header("Idempotency-Key", UUID.randomUUID().toString())
                        .contentType(MediaType.APPLICATION_JSON).content("{"))
                .andExpect(status().isBadRequest());
        mvc.perform(post(PATH).header("Authorization", bearer(customer))
                        .header("Idempotency-Key", UUID.randomUUID().toString())
                        .contentType(MediaType.APPLICATION_JSON).content("{\"quotePublicId\":\"not-a-uuid\"}"))
                .andExpect(status().isBadRequest());
        mvc.perform(post(PATH).header("Authorization", bearer(customer))
                        .header("Idempotency-Key", UUID.randomUUID().toString())
                        .contentType(MediaType.APPLICATION_JSON).content("{\"quotePublicId\":\"" + quote.getPublicId()
                                + "\",\"customerId\":" + other.getId() + ",\"finalFare\":1}"))
                .andExpect(status().isBadRequest());
        mvc.perform(post(PATH).header("Authorization", bearer(customer))
                        .header("Idempotency-Key", UUID.randomUUID().toString())
                        .contentType(MediaType.APPLICATION_JSON).content(request(otherQuote)))
                .andExpect(status().isNotFound()).andExpect(jsonPath("$.code").value("QUOTE_NOT_FOUND"));

        Call created = call(customer, quote, key);
        assertThat(created.status()).isEqualTo(201);
        JsonNode data = mapper.readTree(created.body()).path("data");
        UUID bookingPublicId = UUID.fromString(data.path("bookingPublicId").asText());
        assertThat(data.path("quotePublicId").asText()).isEqualTo(quote.getPublicId().toString());
        assertThat(data.path("status").asText()).isEqualTo("REQUESTED");
        assertThat(data.path("finalFare").decimalValue()).isEqualByComparingTo(quote.getFinalFare());
        assertThat(data.has("id")).isFalse();
        assertThat(data.has("customerId")).isFalse();
        assertThat(mapper.readTree(created.body()).path("timestamp").asText()).isEqualTo(FIXED.toString());

        clock.set(FIXED.plusSeconds(60));
        Call replay = call(customer, quote, key);
        assertThat(replay.status()).isEqualTo(201);
        assertThat(replay.body()).isEqualTo(created.body());
        assertThat(bookings.countByQuoteId(quote.getId())).isEqualTo(1);
        assertThat(idempotencyCount(customer, key)).isEqualTo(1);
        assertThat(quotes.findById(quote.getId()).orElseThrow().getStatus()).isEqualTo(QuoteStatus.CONSUMED);

        mvc.perform(get(PATH + "/" + bookingPublicId)).andExpect(status().isUnauthorized());
        mvc.perform(get(PATH + "/" + bookingPublicId).header("Authorization", bearer(driver)))
                .andExpect(status().isForbidden());
        mvc.perform(get(PATH + "/" + bookingPublicId).header("Authorization", bearer(other)))
                .andExpect(status().isNotFound()).andExpect(jsonPath("$.code").value("BOOKING_NOT_FOUND"));
        mvc.perform(get(PATH + "/" + bookingPublicId).header("Authorization", bearer(customer)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.data.status").value("REQUESTED"))
                .andExpect(jsonPath("$.data.finalFare").value(35400.00))
                .andExpect(jsonPath("$.data.id").doesNotExist());
    }

    @Test
    void keyReuseWithDifferentRequestConflictsBeforeTouchingLosingQuote() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        Quote first = quote(customer);
        Quote losing = quote(customer);
        String key = UUID.randomUUID().toString();

        assertThat(call(customer, first, key).status()).isEqualTo(201);
        Call mismatch = call(customer, losing, key);

        assertThat(mismatch.status()).isEqualTo(409);
        assertThat(mapper.readTree(mismatch.body()).path("code").asText()).isEqualTo("IDEMPOTENCY_KEY_REUSED");
        assertThat(quotes.findById(losing.getId()).orElseThrow().getStatus()).isEqualTo(QuoteStatus.ISSUED);
        assertThat(bookings.countByQuoteId(losing.getId())).isZero();
    }

    @Test
    void bookingCopiesImmutableFareAndSpatialSnapshotWithoutRepricing() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        Quote quote = quote(customer);
        Call created = call(customer, quote, UUID.randomUUID().toString());
        UUID bookingPublicId = UUID.fromString(mapper.readTree(created.body()).path("data").path("bookingPublicId").asText());
        Booking booking = bookings.findOwned(bookingPublicId, customer.getPublicId()).orElseThrow();

        assertThat(booking.getStatus()).isEqualTo(BookingStatus.REQUESTED);
        assertThat(booking.getFinalFare()).isEqualTo(quote.getFinalFare());
        assertThat(booking.getPricingEngineVersion()).isEqualTo(quote.getPricingEngineVersion());
        assertThat(booking.getPricingSnapshot()).isEqualTo(quote.getPricingSnapshot());
        assertThat(booking.getPickupLocation().getSRID()).isEqualTo(4326);
        assertThat(booking.getDropoffLocation().getSRID()).isEqualTo(4326);
        assertThat(booking.getDistanceMeters()).isEqualTo(quote.getDistanceMeters());
        assertThatThrownBy(() -> booking.getPricingSnapshot().put("finalFare", "1.00"))
                .isInstanceOf(UnsupportedOperationException.class);

        PricingProperties.Tariff tariff = pricingProperties.getTariffs().get(VehicleType.MOTORBIKE);
        BigDecimal original = tariff.getBaseFare();
        try {
            tariff.setBaseFare(new BigDecimal("99000.00"));
            assertThat(pricing.calculate(VehicleType.MOTORBIKE,
                    new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "TEST")).finalFare())
                    .isNotEqualTo(booking.getFinalFare());
            mvc.perform(get(PATH + "/" + bookingPublicId).header("Authorization", bearer(customer)))
                    .andExpect(status().isOk()).andExpect(jsonPath("$.data.finalFare").value(35400.00));
        } finally {
            tariff.setBaseFare(original);
        }
        assertThat(bookings.findOwned(bookingPublicId, customer.getPublicId()).orElseThrow().getFinalFare())
                .isEqualTo(quote.getFinalFare());
    }

    @Test
    void v10SchemaConstraintsAndForeignKeysAreInstalled() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        Quote first = quote(customer);
        Quote second = quote(customer);
        UUID firstBooking = UUID.fromString(mapper.readTree(call(customer, first, UUID.randomUUID().toString()).body())
                .path("data").path("bookingPublicId").asText());
        UUID secondBooking = UUID.fromString(mapper.readTree(call(customer, second, UUID.randomUUID().toString()).body())
                .path("data").path("bookingPublicId").asText());
        Booking another = bookings.findOwned(secondBooking, customer.getPublicId()).orElseThrow();

        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM flyway_schema_history WHERE version='10' AND success=TRUE", Integer.class))
                .isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT to_regclass('public.bookings') IS NOT NULL", Boolean.class)).isTrue();
        assertThat(jdbc.queryForObject("SELECT to_regclass('public.booking_idempotency') IS NOT NULL", Boolean.class)).isTrue();
        for (String column : new String[]{"pickup_location", "dropoff_location"}) {
            assertThat(jdbc.queryForObject("""
                    SELECT format_type(a.atttypid, a.atttypmod)
                    FROM pg_attribute a WHERE a.attrelid='bookings'::regclass AND a.attname=?
                    """, String.class, column)).containsIgnoringCase("geography(Point,4326)");
        }
        assertThat(jdbc.queryForObject("""
                SELECT data_type FROM information_schema.columns
                WHERE table_name='bookings' AND column_name='pricing_snapshot'
                """, String.class)).isEqualTo("jsonb");
        assertThat(jdbc.queryForObject("""
                SELECT numeric_precision FROM information_schema.columns
                WHERE table_name='bookings' AND column_name='final_fare'
                """, Integer.class)).isEqualTo(15);
        assertThat(jdbc.queryForObject("""
                SELECT numeric_scale FROM information_schema.columns
                WHERE table_name='bookings' AND column_name='final_fare'
                """, Integer.class)).isEqualTo(2);
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM pg_constraint
                WHERE conrelid='bookings'::regclass AND contype='f'
                  AND confrelid IN ('users'::regclass, 'quotes'::regclass)
                """, Integer.class)).isEqualTo(2);
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM pg_constraint
                WHERE conrelid='bookings'::regclass AND conname='uq_bookings_quote_id'
                """, Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM pg_constraint
                WHERE conrelid='booking_idempotency'::regclass AND conname='uq_booking_idempotency_customer_key'
                """, Integer.class)).isEqualTo(1);
        assertThatThrownBy(() -> jdbc.update("UPDATE bookings SET quote_id=? WHERE id=?", first.getId(), another.getId()))
                .isInstanceOf(DataIntegrityViolationException.class);
        assertThat(bookings.findOwned(firstBooking, customer.getPublicId())).isPresent();
    }

    @Test
    void transactionRollbackLeavesNoBookingConsumptionOrOutcome() {
        User customer = user(UserRole.CUSTOMER);
        Quote quote = quote(customer);
        String key = UUID.randomUUID().toString();
        jdbc.execute("ALTER TABLE booking_idempotency ADD CONSTRAINT chk_v10_test_force_failure CHECK (booking_id IS NULL) NOT VALID");
        try {
            assertThatThrownBy(() -> bookingService.create(customer.getPublicId(), UserRole.CUSTOMER,
                    quote.getPublicId(), key)).isInstanceOf(DataIntegrityViolationException.class);
        } finally {
            jdbc.execute("ALTER TABLE booking_idempotency DROP CONSTRAINT chk_v10_test_force_failure");
        }
        assertThat(bookings.countByQuoteId(quote.getId())).isZero();
        Quote reloaded = quotes.findById(quote.getId()).orElseThrow();
        assertThat(reloaded.getStatus()).isEqualTo(QuoteStatus.ISSUED);
        assertThat(reloaded.getConsumedAt()).isNull();
        assertThat(idempotencyCount(customer, key)).isZero();
    }

    @Test
    void concurrentSameKeyAndQuoteReplaysOneCommittedOutcome() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        Quote quote = quote(customer);
        String key = UUID.randomUUID().toString();

        List<Call> results = race(() -> call(customer, quote, key), () -> call(customer, quote, key));

        assertThat(results).extracting(Call::status).containsExactlyInAnyOrder(201, 201);
        assertThat(results.get(0).body()).isEqualTo(results.get(1).body());
        assertThat(bookings.countByQuoteId(quote.getId())).isEqualTo(1);
        assertThat(idempotencyCount(customer, key)).isEqualTo(1);
        Quote consumed = quotes.findById(quote.getId()).orElseThrow();
        assertThat(consumed.getStatus()).isEqualTo(QuoteStatus.CONSUMED);
        assertThat(consumed.getConsumedAt()).isEqualTo(FIXED);
    }

    @Test
    void concurrentDifferentKeysCannotBookOneQuoteTwice() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        Quote quote = quote(customer);
        String firstKey = UUID.randomUUID().toString();
        String secondKey = UUID.randomUUID().toString();

        List<Call> results = race(() -> call(customer, quote, firstKey),
                () -> call(customer, quote, secondKey));

        assertThat(results).extracting(Call::status).containsExactlyInAnyOrder(201, 409);
        Call rejected = results.stream().filter(call -> call.status() == 409).findFirst().orElseThrow();
        assertThat(mapper.readTree(rejected.body()).path("code").asText()).isEqualTo("QUOTE_ALREADY_CONSUMED");
        assertThat(bookings.countByQuoteId(quote.getId())).isEqualTo(1);
        assertThat(idempotencyCount(customer, firstKey) + idempotencyCount(customer, secondKey)).isEqualTo(1);
    }

    @Test
    void concurrentSameKeyDifferentQuotesLeavesLosingQuoteAvailable() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        Quote first = quote(customer);
        Quote second = quote(customer);
        String key = UUID.randomUUID().toString();

        List<Call> results = race(() -> call(customer, first, key), () -> call(customer, second, key));

        assertThat(results).extracting(Call::status).containsExactlyInAnyOrder(201, 409);
        Call rejected = results.stream().filter(call -> call.status() == 409).findFirst().orElseThrow();
        assertThat(mapper.readTree(rejected.body()).path("code").asText()).isEqualTo("IDEMPOTENCY_KEY_REUSED");
        Quote losing = results.get(0).status() == 409 ? first : second;
        assertThat(quotes.findById(losing.getId()).orElseThrow().getStatus()).isEqualTo(QuoteStatus.ISSUED);
        assertThat(bookings.countByQuoteId(losing.getId())).isZero();
        assertThat(idempotencyCount(customer, key)).isEqualTo(1);
        assertThat(call(customer, losing, UUID.randomUUID().toString()).status()).isEqualTo(201);
    }

    @Test
    void quoteExpiringWhileWaitingForRowLockCannotBeConsumed() throws Exception {
        User customer = user(UserRole.CUSTOMER);
        Quote quote = quote(customer);
        String key = UUID.randomUUID().toString();
        ExecutorService executor = Executors.newSingleThreadExecutor();
        try (Connection holder = dataSource.getConnection()) {
            holder.setAutoCommit(false);
            int holderPid;
            try (PreparedStatement statement = holder.prepareStatement("SELECT pg_backend_pid()")) {
                try (var rows = statement.executeQuery()) {
                    rows.next();
                    holderPid = rows.getInt(1);
                }
            }
            try (PreparedStatement statement = holder.prepareStatement("SELECT id FROM quotes WHERE id=? FOR UPDATE")) {
                statement.setLong(1, quote.getId());
                statement.executeQuery().close();
            }

            Future<String> waiting = executor.submit(() -> {
                try {
                    bookingService.create(customer.getPublicId(), UserRole.CUSTOMER,
                            quote.getPublicId(), key);
                    return "SUCCESS";
                } catch (DomainException ex) {
                    return ex.getCode();
                }
            });
            try {
                awaitBlockedBy(holderPid);
                clock.set(FIXED.plusSeconds(60));
                holder.commit();
                assertThat(waiting.get(10, TimeUnit.SECONDS)).isEqualTo("QUOTE_EXPIRED");
            } finally {
                holder.rollback();
            }
        } finally {
            executor.shutdownNow();
        }
        assertThat(bookings.countByQuoteId(quote.getId())).isZero();
        assertThat(quotes.findById(quote.getId()).orElseThrow().getStatus()).isEqualTo(QuoteStatus.ISSUED);
        assertThat(idempotencyCount(customer, key)).isZero();
    }

    @Test
    void sameKeyIsIndependentForDistinctCustomers() throws Exception {
        User firstCustomer = user(UserRole.CUSTOMER);
        User secondCustomer = user(UserRole.CUSTOMER);
        Quote firstQuote = quote(firstCustomer);
        Quote secondQuote = quote(secondCustomer);
        String key = UUID.randomUUID().toString();

        List<Call> results = race(() -> call(firstCustomer, firstQuote, key),
                () -> call(secondCustomer, secondQuote, key));

        assertThat(results).extracting(Call::status).containsExactlyInAnyOrder(201, 201);
        assertThat(mapper.readTree(results.get(0).body()).path("data").path("bookingPublicId").asText())
                .isNotEqualTo(mapper.readTree(results.get(1).body()).path("data").path("bookingPublicId").asText());
        assertThat(idempotencyCount(firstCustomer, key)).isEqualTo(1);
        assertThat(idempotencyCount(secondCustomer, key)).isEqualTo(1);
        assertThat(bookings.countByQuoteId(firstQuote.getId())).isEqualTo(1);
        assertThat(bookings.countByQuoteId(secondQuote.getId())).isEqualTo(1);
    }

    private void awaitBlockedBy(int holderPid) {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(4);
        while (System.nanoTime() < deadline) {
            Boolean blocked = jdbc.queryForObject("""
                    SELECT EXISTS (
                        SELECT 1 FROM pg_stat_activity
                        WHERE wait_event_type = 'Lock' AND ? = ANY(pg_blocking_pids(pid))
                    )
                    """, Boolean.class, holderPid);
            if (Boolean.TRUE.equals(blocked)) return;
            LockSupport.parkNanos(TimeUnit.MILLISECONDS.toNanos(10));
        }
        throw new AssertionError("Booking transaction did not wait for the Quote row lock");
    }

    private List<Call> race(Callable<Call> first, Callable<Call> second) throws Exception {
        ExecutorService executor = Executors.newFixedThreadPool(2);
        CountDownLatch ready = new CountDownLatch(2);
        CountDownLatch start = new CountDownLatch(1);
        try {
            Future<Call> one = executor.submit(() -> { ready.countDown(); start.await(); return first.call(); });
            Future<Call> two = executor.submit(() -> { ready.countDown(); start.await(); return second.call(); });
            assertThat(ready.await(5, TimeUnit.SECONDS)).isTrue();
            start.countDown();
            return List.of(one.get(10, TimeUnit.SECONDS), two.get(10, TimeUnit.SECONDS));
        } finally {
            executor.shutdownNow();
        }
    }

    private User user(UserRole role) {
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        User user = users.saveAndFlush(new User("09" + Long.toUnsignedString(System.nanoTime(), 36),
                "booking-" + suffix + "@example.test", "hash", "Booking Test"));
        user.setRole(role);
        return users.saveAndFlush(user);
    }

    private Quote quote(User customer) {
        RouteEstimate route = new RouteEstimate(new BigDecimal("5200"), new BigDecimal("840"), "TEST_ROUTER");
        return quotes.saveAndFlush(new Quote(customer,
                new GeoCoordinate(new BigDecimal("21.0287"), new BigDecimal("105.8524")),
                new GeoCoordinate(new BigDecimal("21.0245"), new BigDecimal("105.8576")),
                VehicleType.MOTORBIKE, route, pricing.calculate(VehicleType.MOTORBIKE, route), clock.instant()));
    }

    private String bearer(User user) {
        return "Bearer " + jwt.createAccessToken(user);
    }

    private String request(Quote quote) {
        return "{\"quotePublicId\":\"" + quote.getPublicId() + "\"}";
    }

    private Call call(User customer, Quote quote, String key) throws Exception {
        MvcResult result = mvc.perform(post(PATH).header("Authorization", bearer(customer))
                        .header("Idempotency-Key", key)
                        .contentType(MediaType.APPLICATION_JSON).content(request(quote)))
                .andReturn();
        return new Call(result.getResponse().getStatus(), result.getResponse().getContentAsString());
    }

    private long idempotencyCount(User customer, String key) {
        return jdbc.queryForObject("""
                SELECT COUNT(*) FROM booking_idempotency WHERE customer_id=? AND idempotency_key=?
                """, Long.class, customer.getId(), key);
    }

    private record Call(int status, String body) {}

    static class MutableClock extends Clock {
        private final AtomicReference<Instant> now = new AtomicReference<>(FIXED);

        void set(Instant value) { now.set(value); }
        @Override public ZoneId getZone() { return ZoneOffset.UTC; }
        @Override public Clock withZone(ZoneId zone) { return Clock.fixed(now.get(), zone); }
        @Override public Instant instant() { return now.get(); }
    }

    @TestConfiguration
    static class ClockConfiguration {
        @Bean @Primary MutableClock bookingTestClock() { return new MutableClock(); }
    }
}
