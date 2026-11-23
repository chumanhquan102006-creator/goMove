package com.gomove.common;

import com.zaxxer.hikari.HikariDataSource;
import org.junit.jupiter.api.BeforeEach;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

import javax.sql.DataSource;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest
@ActiveProfiles("test")
public abstract class BaseIntegrationTest {

    @Autowired private DataSource integrationTestDataSource;

    @BeforeEach
    void verifyTestConnectionPool() {
        assertThat(integrationTestDataSource).isInstanceOf(HikariDataSource.class);
        HikariDataSource pool = (HikariDataSource) integrationTestDataSource;
        assertThat(pool.getMaximumPoolSize()).as("%s maximum pool size", pool.getPoolName()).isEqualTo(4);
        assertThat(pool.getMinimumIdle()).as("%s minimum idle", pool.getPoolName()).isEqualTo(1);
    }

    protected static final PostgreSQLContainer<?> postgres;

    static {
        String image = System.getProperty("gomove.test.postgis-image", "postgis/postgis:16-3.5");
        postgres = new PostgreSQLContainer<>(DockerImageName.parse(image)
                .asCompatibleSubstituteFor("postgres"))
                .withDatabaseName("test")
                .withUsername("test")
                .withPassword("test");
        postgres.start();
    }

    @DynamicPropertySource
    static void configureProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", postgres::getJdbcUrl);
        registry.add("spring.datasource.username", postgres::getUsername);
        registry.add("spring.datasource.password", postgres::getPassword);
    }
}
