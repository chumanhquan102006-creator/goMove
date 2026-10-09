package com.gomove.trip.realtime;

import com.gomove.common.security.CustomUserPrincipal;
import com.gomove.location.api.UpdateDriverLocationRequest;
import com.gomove.trip.service.TripApplicationService;
import org.springframework.messaging.handler.annotation.DestinationVariable;
import org.springframework.messaging.handler.annotation.MessageMapping;
import org.springframework.messaging.handler.annotation.Payload;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.stereotype.Controller;

import java.security.Principal;
import java.util.UUID;

@Controller
public class TripLocationMessageController {
    private final TripApplicationService trips;

    public TripLocationMessageController(TripApplicationService trips) { this.trips = trips; }

    @MessageMapping("/ride/{bookingPublicId}/location")
    public void update(@DestinationVariable UUID bookingPublicId,
                       @Payload UpdateDriverLocationRequest request, Principal principal) {
        var user = (CustomUserPrincipal) ((UsernamePasswordAuthenticationToken) principal).getPrincipal();
        trips.updateRideLocation(bookingPublicId, user.publicId(), user.role(), request);
    }
}
