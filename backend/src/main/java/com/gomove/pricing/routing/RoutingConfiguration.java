package com.gomove.pricing.routing;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

import java.net.URI;

@Configuration
public class RoutingConfiguration {
    @Bean
    RestClient osrmRestClient(OsrmProperties properties) {
        String baseUrl = properties.getBaseUrl();
        try {
            URI uri = URI.create(baseUrl);
            if (!("http".equalsIgnoreCase(uri.getScheme()) || "https".equalsIgnoreCase(uri.getScheme()))
                    || uri.getHost() == null || uri.getRawUserInfo() != null
                    || uri.getRawQuery() != null || uri.getRawFragment() != null) {
                throw new IllegalArgumentException("Invalid OSRM base URL");
            }
        } catch (IllegalArgumentException | NullPointerException ex) {
            throw new IllegalArgumentException("OSRM base URL must be an absolute HTTP(S) URL without credentials, query or fragment", ex);
        }
        if (properties.getConnectTimeout() == null || properties.getConnectTimeout().isNegative()
                || properties.getConnectTimeout().isZero() || properties.getReadTimeout() == null
                || properties.getReadTimeout().isNegative() || properties.getReadTimeout().isZero()) {
            throw new IllegalArgumentException("OSRM timeouts must be positive");
        }
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout(properties.getConnectTimeout());
        requestFactory.setReadTimeout(properties.getReadTimeout());
        return RestClient.builder().requestFactory(requestFactory).build();
    }
}
