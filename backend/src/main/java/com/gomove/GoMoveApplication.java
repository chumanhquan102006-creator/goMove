package com.gomove;

import com.gomove.auth.infrastructure.AuthProperties;
import com.gomove.dispatch.service.DispatchProperties;
import com.gomove.location.infrastructure.LocationProperties;
import com.gomove.pricing.engine.PricingProperties;
import com.gomove.pricing.routing.OsrmProperties;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.scheduling.annotation.EnableScheduling;

@SpringBootApplication
@EnableScheduling
@EnableConfigurationProperties({AuthProperties.class, LocationProperties.class, PricingProperties.class,
        OsrmProperties.class, DispatchProperties.class})
public class GoMoveApplication {
    public static void main(String[] args) { SpringApplication.run(GoMoveApplication.class, args); }
}
