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

## Transient road ETA (M4.5A)

`GET /api/v1/bookings/{bookingPublicId}/eta` is available only to the Booking
Customer and assigned Driver. Its `data` contains the current Booking `status`,
`phase` (`PICKUP`, `DESTINATION`, or `NONE`), `availability`, optional `reason`,
road `distanceMeters` and `durationSeconds`, `calculatedAt`, `locationUpdatedAt`,
`expiresAt`, and `servedAt`. It contains no GPS coordinates. `DRIVER_ACCEPTED`
routes the latest Driver position to pickup; `IN_PROGRESS` routes it to dropoff.
Other states return `UNAVAILABLE` without reading a Driver position. ETA reads
never alter the accepted fare, Quote, Booking, or CASH records.

The Backend requires a latest GPS row no older than the existing 30-second
dispatch freshness policy, with reported accuracy at most 100 meters. A null
accuracy is unavailable. The OSRM response must snap both endpoints within
200 meters. A bad fix, missing route, timeout, or invalid response produces a
neutral `UNAVAILABLE` result. Live ETA uses a transient OSRM metrics request;
the immutable Quote route remains the blue map polyline and is never repriced.
The new live route may differ from that original polyline if the Driver goes
off the original route.

For each Booking, a bounded in-memory cache holds at most a 30-second estimate.
It recalculates after at least 15 seconds when GPS has moved 50 meters or more,
or when the old estimate expires; a routing failure has a 15-second retry
cooldown. Each request rechecks authorized Booking status, GPS freshness and
accuracy before using the cache. A request also rechecks state after OSRM
returns, discarding a result superseded by completion or material GPS movement.
`expiresAt` never exceeds the source GPS freshness boundary. Clients use
`expiresAt - servedAt` as a local monotonic display TTL, capped at 30 seconds,
so an incorrect device clock cannot extend the estimate. Do not count an ETA
down without a new valid estimate.

GPS freshness is based on server receipt time: the V12 location payload has no
original Android sample timestamp. Existing mobile sample-age checks reduce
the risk of replaying an old fix, but the Backend cannot independently prove
the age of a resampled coordinate. An exact arrival at a routing endpoint may
yield zero OSRM metrics, for which this endpoint returns `UNAVAILABLE` rather
than inventing a remaining time.
