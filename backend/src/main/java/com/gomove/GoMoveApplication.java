package com.gomove;

import com.gomove.auth.infrastructure.AuthProperties;
import com.gomove.location.infrastructure.LocationProperties;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;

@SpringBootApplication
@EnableConfigurationProperties({AuthProperties.class, LocationProperties.class})
public class GoMoveApplication {
    public static void main(String[] args) { SpringApplication.run(GoMoveApplication.class, args); }
}
