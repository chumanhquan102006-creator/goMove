package com.gomove.pricing.weather;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

import java.io.IOException;
import java.net.URI;
import java.net.HttpURLConnection;

@Configuration
public class WeatherConfiguration {
    @Bean
    RestClient openMeteoWeatherRestClient(WeatherPricingProperties properties) {
        validateEndpoint(properties.getBaseUrl());
        if (!positive(properties.getConnectTimeout()) || !positive(properties.getReadTimeout())) {
            throw new IllegalArgumentException("Weather provider timeouts must be positive");
        }
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory() {
            @Override
            protected void prepareConnection(HttpURLConnection connection, String httpMethod) throws IOException {
                super.prepareConnection(connection, httpMethod);
                connection.setInstanceFollowRedirects(false);
            }
        };
        requestFactory.setConnectTimeout(properties.getConnectTimeout());
        requestFactory.setReadTimeout(properties.getReadTimeout());
        return RestClient.builder().requestFactory(requestFactory).build();
    }

    static void validateEndpoint(String baseUrl) {
        try {
            URI uri = URI.create(baseUrl);
            if (!"https".equalsIgnoreCase(uri.getScheme())
                    || !"api.open-meteo.com".equalsIgnoreCase(uri.getHost())
                    || (uri.getPort() != -1 && uri.getPort() != 443)
                    || (uri.getRawPath() != null && !uri.getRawPath().isEmpty() && !"/".equals(uri.getRawPath()))
                    || uri.getRawUserInfo() != null || uri.getRawQuery() != null || uri.getRawFragment() != null) {
                throw new IllegalArgumentException();
            }
        } catch (IllegalArgumentException | NullPointerException ex) {
            throw new IllegalArgumentException("Weather provider URL must be the fixed HTTPS Open-Meteo endpoint", ex);
        }
    }

    private static boolean positive(java.time.Duration duration) {
        return duration != null && !duration.isNegative() && !duration.isZero();
    }
}
