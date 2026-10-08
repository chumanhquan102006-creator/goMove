package com.gomove.pricing.service;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.time.Clock;

@Configuration
public class QuoteClockConfiguration {
    @Bean
    Clock quoteClock() {
        return Clock.systemUTC();
    }
}
