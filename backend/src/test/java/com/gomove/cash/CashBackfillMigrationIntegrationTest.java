package com.gomove.cash;

import com.gomove.cash.infrastructure.CashSettlementStore;
import com.gomove.cash.service.CashSettlementTransactionService;
import com.gomove.cash.service.CommissionCalculator;
import com.gomove.common.BaseIntegrationTest;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationVersion;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.Clock;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class CashBackfillMigrationIntegrationTest extends BaseIntegrationTest {
    @Test
    void completedPreV13BookingBackfillsPendingAndCanBeSettledWithoutInventedHistory() throws Exception {
        String schema = "v13_backfill_" + UUID.randomUUID().toString().replace("-", "");
        String url = postgres.getJdbcUrl() + "&currentSchema=" + schema + ",public";
        DriverManagerDataSource source = new DriverManagerDataSource(url,
                postgres.getUsername(), postgres.getPassword());
        JdbcTemplate jdbc = new JdbcTemplate(source);
        UUID driverUserPublicId = UUID.randomUUID();
        UUID bookingPublicId = UUID.randomUUID();
        try {
            Flyway.configure().dataSource(source).defaultSchema(schema).schemas(schema, "public")
                    .locations("classpath:db/migration")
                    .target(MigrationVersion.fromVersion("12")).load().migrate();
            try (Connection connection = source.getConnection(); Statement statement = connection.createStatement()) {
                long customerId = id(statement, """
                        INSERT INTO users (public_id, phone, password_hash, full_name, role)
                        VALUES ('00000000-0000-4000-8000-000000000001', '09000000001', 'hash', 'Customer', 'CUSTOMER')
                        RETURNING id
                        """);
                long driverUserId = id(statement, """
                        INSERT INTO users (public_id, phone, password_hash, full_name, role)
                        VALUES ('%s', '09000000002', 'hash', 'Driver', 'DRIVER') RETURNING id
                        """.formatted(driverUserPublicId));
                long driverId = id(statement, """
                        INSERT INTO drivers (public_id, user_id, license_number, approval_status, operating_status)
                        VALUES ('00000000-0000-4000-8000-000000000003', %d, 'BACKFILL-LICENSE', 'APPROVED', 'BUSY')
                        RETURNING id
                        """.formatted(driverUserId));
                long vehicleId = id(statement, """
                        INSERT INTO vehicles (public_id, driver_id, license_plate, vehicle_type, is_active)
                        VALUES ('00000000-0000-4000-8000-000000000004', %d, 'BACKFILL-PLATE', 'MOTORBIKE', TRUE)
                        RETURNING id
                        """.formatted(driverId));
                long quoteId = id(statement, """
                        INSERT INTO quotes (public_id, customer_id, pickup_location, dropoff_location,
                            distance_meters, duration_seconds, routing_provider, vehicle_type, currency_code,
                            base_fare, distance_fare, time_fare, surcharge, surge_multiplier, surge_amount,
                            discount_amount, rounding_adjustment, final_fare, pricing_engine_version,
                            pricing_snapshot, status, issued_at, expires_at, consumed_at)
                        VALUES ('00000000-0000-4000-8000-000000000005', %d,
                            ST_SetSRID(ST_MakePoint(105.8,21.0),4326)::geography,
                            ST_SetSRID(ST_MakePoint(105.9,21.1),4326)::geography,
                            1000, 600, 'TEST', 'MOTORBIKE', 'VND', 35400.00, 0, 0, 0, 1, 0,
                            0, 0, 35400.00, 'MVP_V1', '{}', 'CONSUMED',
                            CURRENT_TIMESTAMP - INTERVAL '5 minutes',
                            CURRENT_TIMESTAMP - INTERVAL '4 minutes',
                            CURRENT_TIMESTAMP - INTERVAL '4 minutes 30 seconds') RETURNING id
                        """.formatted(customerId));
                id(statement, """
                        INSERT INTO bookings (public_id, customer_id, quote_id, status,
                            pickup_location, dropoff_location, distance_meters, duration_seconds,
                            routing_provider, vehicle_type, currency_code, final_fare,
                            pricing_engine_version, pricing_snapshot, assigned_driver_id,
                            assigned_vehicle_id, driver_accepted_at, driver_arrived_at,
                            passenger_onboard_at, trip_started_at, trip_completed_at)
                        VALUES ('%s', %d, %d, 'COMPLETED',
                            ST_SetSRID(ST_MakePoint(105.8,21.0),4326)::geography,
                            ST_SetSRID(ST_MakePoint(105.9,21.1),4326)::geography,
                            1000, 600, 'TEST', 'MOTORBIKE', 'VND', 35400.00,
                            'MVP_V1', '{}', %d, %d,
                            CURRENT_TIMESTAMP - INTERVAL '4 minutes',
                            CURRENT_TIMESTAMP - INTERVAL '3 minutes',
                            CURRENT_TIMESTAMP - INTERVAL '2 minutes',
                            CURRENT_TIMESTAMP - INTERVAL '1 minute',
                            CURRENT_TIMESTAMP) RETURNING id
                        """.formatted(bookingPublicId, customerId, quoteId, driverId, vehicleId));
            }
            assertThat(jdbc.queryForObject("""
                    SELECT COUNT(*) FROM information_schema.tables
                    WHERE table_schema=? AND table_name='cash_payments'
                    """, Integer.class, schema)).isZero();
            Flyway.configure().dataSource(source).defaultSchema(schema).schemas(schema, "public")
                    .locations("classpath:db/migration").load().migrate();
            assertThat(jdbc.queryForObject("""
                    SELECT version FROM flyway_schema_history WHERE success=TRUE
                    ORDER BY installed_rank DESC LIMIT 1
                    """, String.class)).isEqualTo("14");
            assertThat(jdbc.queryForObject("SELECT status FROM cash_payments", String.class))
                    .isEqualTo("PENDING");
            assertThat(jdbc.queryForObject("SELECT amount FROM cash_payments", BigDecimal.class))
                    .isEqualByComparingTo("35400.00");
            assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM driver_commission_ledger", Integer.class))
                    .isZero();
            CashSettlementTransactionService settlement = new CashSettlementTransactionService(
                    new CashSettlementStore(jdbc),
                    new CommissionCalculator(new BigDecimal("0.20"), "CASH_MVP_V1"), Clock.systemUTC());
            var receipt = new TransactionTemplate(new DataSourceTransactionManager(source))
                    .execute(status -> settlement.confirm(bookingPublicId, driverUserPublicId));
            assertThat(receipt).isNotNull();
            assertThat(receipt.commissionAmount()).isEqualByComparingTo("7080.00");
            assertThat(jdbc.queryForObject("SELECT operating_status FROM drivers", String.class))
                    .isEqualTo("ONLINE");
            assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM driver_commission_ledger", Integer.class))
                    .isEqualTo(1);
        } finally {
            // Only this test-created, random, fully resolved schema is removed.
            try (Connection connection = postgres.createConnection(""); Statement statement = connection.createStatement()) {
                statement.execute("DROP SCHEMA IF EXISTS " + schema + " CASCADE");
            }
        }
    }

    private long id(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            assertThat(result.next()).isTrue();
            return result.getLong(1);
        }
    }
}
