# V12 trip and tracking contract

The Booking row is the trip state source of truth. The assigned driver alone can POST
`/api/v1/drivers/me/trips/{bookingPublicId}/arrive`, `/onboard`, `/start`, and
`/complete`, in that order. A replay or out-of-order action returns 409. The driver
stays `BUSY` and `driver_released_at` stays null after `COMPLETED`; settlement and
release belong to V13.

Connect to `/ws` using a STOMP `Authorization: Bearer <access-token>` CONNECT
header. Participants subscribe to `/topic/ride/{bookingPublicId}`. Only the assigned
driver may SEND JSON `{latitude, longitude, accuracy?, bearing?}` to
`/app/ride/{bookingPublicId}/location` while the Booking is in `DRIVER_ACCEPTED`,
`DRIVER_ARRIVED`, `PASSENGER_ONBOARD`, or `IN_PROGRESS`. Server-generated status and
location events are published after database commit. WebSocket delivery is best
effort; on reconnect, participants should GET
`/api/v1/bookings/{bookingPublicId}/tracking` to recover the latest durable state.

GPS has no client-supplied timestamp or history in V12. For ride-channel updates,
server receipt/Booking-lock order wins; a delayed older sample arriving later can
replace the last position. Clients should send only their freshest fix and use the
server `recordedAt` timestamp when displaying events. The existing V8 profile
location API writes the same latest-location row and can also replace it. There is
no cross-channel sequence guarantee. The STOMP simple broker is in-process and
supports one application instance only; multi-instance delivery needs a future
broker design. `gomove.realtime.allowed-origins` is a comma-separated list of
approved browser origins (default: local development origins only).

Historical `COMPLETED` Bookings expose status, assigned driver identity and lifecycle
timestamps, but never join the driver's current GPS row. Their tracking response has
null latitude, longitude, accuracy, bearing and location timestamp. STOMP CONNECT
registers the JWT expiration against its server session ID. Every private ride frame
is checked again on the client outbound channel; an expired session remains unable
to receive events even if its broker subscription has not yet been removed. The
client must reconnect using a fresh access token.
