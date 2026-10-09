package com.gomove.trip.realtime;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Configuration;
import org.springframework.messaging.simp.config.ChannelRegistration;
import org.springframework.messaging.simp.config.MessageBrokerRegistry;
import org.springframework.web.socket.config.annotation.EnableWebSocketMessageBroker;
import org.springframework.web.socket.config.annotation.StompEndpointRegistry;
import org.springframework.web.socket.config.annotation.WebSocketMessageBrokerConfigurer;

@Configuration
@EnableWebSocketMessageBroker
public class TripWebSocketConfiguration implements WebSocketMessageBrokerConfigurer {
    private final TripInboundAuthorization authorization;
    private final TripOutboundAuthorization outboundAuthorization;
    private final String[] allowedOrigins;

    public TripWebSocketConfiguration(TripInboundAuthorization authorization,
                                      TripOutboundAuthorization outboundAuthorization,
                                      @Value("${gomove.realtime.allowed-origins:http://localhost:3000,http://localhost:8080}")
                                      String allowedOrigins) {
        this.authorization = authorization;
        this.outboundAuthorization = outboundAuthorization;
        this.allowedOrigins = allowedOrigins.split(",");
    }

    @Override
    public void registerStompEndpoints(StompEndpointRegistry registry) {
        registry.addEndpoint("/ws").setAllowedOrigins(allowedOrigins);
    }

    @Override
    public void configureMessageBroker(MessageBrokerRegistry registry) {
        registry.setApplicationDestinationPrefixes("/app");
        registry.enableSimpleBroker("/topic");
    }

    @Override
    public void configureClientInboundChannel(ChannelRegistration registration) {
        registration.interceptors(authorization);
    }

    @Override
    public void configureClientOutboundChannel(ChannelRegistration registration) {
        registration.interceptors(outboundAuthorization);
    }
}
