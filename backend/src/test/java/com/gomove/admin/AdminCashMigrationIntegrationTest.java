package com.gomove.admin;

import com.gomove.common.BaseIntegrationTest;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationVersion;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.Statement;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class AdminCashMigrationIntegrationTest extends BaseIntegrationTest {
    @Test void v17BackfillsTerminalCashWithoutChangingAcceptedFareOrCreatingCommission() throws Exception {
        String schema = "v17_void_" + UUID.randomUUID().toString().replace("-", "");
        var source = new DriverManagerDataSource(postgres.getJdbcUrl() + "&currentSchema=" + schema + ",public",
                postgres.getUsername(), postgres.getPassword());
        var jdbc = new JdbcTemplate(source);
        try {
            Flyway.configure().dataSource(source).defaultSchema(schema).schemas(schema, "public")
                    .locations("classpath:db/migration")
                    .target(MigrationVersion.fromVersion("16")).load().migrate();
            long customerId = jdbc.queryForObject("""
                    INSERT INTO users (public_id, phone, password_hash, full_name, role)
                    VALUES (?, '09123456789', 'hash', 'Migration Customer', 'CUSTOMER') RETURNING id
                    """, Long.class, UUID.randomUUID());
            for (String terminal : new String[]{"CANCELLED", "NO_DRIVER_AVAILABLE"}) {
                long quoteId = jdbc.queryForObject("""
                        INSERT INTO quotes (public_id, customer_id, pickup_location, dropoff_location,
                            distance_meters, duration_seconds, routing_provider, vehicle_type, currency_code,
                            base_fare, distance_fare, time_fare, surcharge, surge_multiplier, surge_amount,
                            discount_amount, rounding_adjustment, final_fare, pricing_engine_version,
                            pricing_snapshot, status, issued_at, expires_at, consumed_at)
                        VALUES (?, ?, ST_SetSRID(ST_MakePoint(105.8,21.0),4326)::geography,
                            ST_SetSRID(ST_MakePoint(105.9,21.1),4326)::geography,
                            1000, 600, 'TEST', 'MOTORBIKE', 'VND', 35400.00, 0, 0, 0,
                            1, 0, 0, 0, 35400.00, 'MVP_V1', '{}', 'CONSUMED',
                            CURRENT_TIMESTAMP - INTERVAL '5 minutes',
                            CURRENT_TIMESTAMP - INTERVAL '4 minutes',
                            CURRENT_TIMESTAMP - INTERVAL '4 minutes 30 seconds') RETURNING id
                        """, Long.class, UUID.randomUUID(), customerId);
                long bookingId = jdbc.queryForObject("""
                        INSERT INTO bookings (public_id, customer_id, quote_id, status,
                            pickup_location, dropoff_location, distance_meters, duration_seconds,
                            routing_provider, vehicle_type, currency_code, final_fare,
                            pricing_engine_version, pricing_snapshot, cancelled_at, cancelled_by,
                            dispatch_failed_at)
                        VALUES (?, ?, ?, ?,
                            ST_SetSRID(ST_MakePoint(105.8,21.0),4326)::geography,
                            ST_SetSRID(ST_MakePoint(105.9,21.1),4326)::geography,
                            1000, 600, 'TEST', 'MOTORBIKE', 'VND', 35400.00,
                            'MVP_V1', '{}',
                            CASE WHEN ? = 'CANCELLED' THEN CURRENT_TIMESTAMP END,
                            CASE WHEN ? = 'CANCELLED' THEN 'CUSTOMER' END,
                            CASE WHEN ? = 'NO_DRIVER_AVAILABLE' THEN CURRENT_TIMESTAMP END)
                        RETURNING id
                        """, Long.class, UUID.randomUUID(), customerId, quoteId, terminal,
                        terminal, terminal, terminal);
                jdbc.update("""
                        INSERT INTO cash_payments (public_id, booking_id, status, amount, currency_code)
                        VALUES (?, ?, 'PENDING', 35400.00, 'VND')
                        """, UUID.randomUUID(), bookingId);
            }
            assertThat(jdbc.queryForObject("SELECT count(*) FROM cash_payments WHERE status='PENDING'",
                    Long.class)).isEqualTo(2);
            Flyway flyway = Flyway.configure().dataSource(source).defaultSchema(schema)
                    .schemas(schema, "public").locations("classpath:db/migration").load();
            flyway.migrate();
            flyway.migrate();
            assertThat(jdbc.queryForObject("SELECT count(*) FROM cash_payments WHERE status='VOID'",
                    Long.class)).isEqualTo(2);
            assertThat(jdbc.queryForObject("SELECT sum(amount) FROM cash_payments",
                    BigDecimal.class)).isEqualByComparingTo("70800.00");
            assertThat(jdbc.queryForObject("SELECT count(*) FROM driver_commission_ledger",
                    Long.class)).isZero();
            assertThat(jdbc.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE version='17' AND success",
                    Long.class)).isEqualTo(1);
        } finally {
            try (Connection connection = postgres.createConnection(""); Statement statement = connection.createStatement()) {
                statement.execute("DROP SCHEMA IF EXISTS " + schema + " CASCADE");
            }
        }
    }
}
