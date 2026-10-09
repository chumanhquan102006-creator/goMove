package com.gomove.trip.realtime;

import org.springframework.messaging.Message;
import org.springframework.messaging.MessageChannel;
import org.springframework.messaging.simp.SimpMessageHeaderAccessor;
import org.springframework.messaging.simp.SimpMessageType;
import org.springframework.messaging.support.ChannelInterceptor;
import org.springframework.stereotype.Component;

@Component
public class TripOutboundAuthorization implements ChannelInterceptor {
    private final TripSessionRegistry sessions;

    public TripOutboundAuthorization(TripSessionRegistry sessions) { this.sessions = sessions; }

    @Override
    public Message<?> preSend(Message<?> message, MessageChannel channel) {
        if (SimpMessageHeaderAccessor.getMessageType(message.getHeaders()) != SimpMessageType.MESSAGE) {
            return message;
        }
        // The broker supplies the destination session ID, not the publisher's principal.
        // Fail closed for every private ride frame immediately before outbound delivery.
        String destination = SimpMessageHeaderAccessor.getDestination(message.getHeaders());
        if (destination != null && destination.startsWith("/topic/ride/")) {
            return sessions.isCurrent(SimpMessageHeaderAccessor.getSessionId(message.getHeaders()))
                    ? message : null;
        }
        return message;
    }
}
