# Follow-up Backend contract: authorized road-route geometry

This is a proposal for a separate Backend review, **not** an implemented M4.4B
API. The mobile app must keep pickup/dropoff markers and omit a road line until
an authorized geometry response exists. It must not ask a public OSRM server or
join the endpoints with a straight line and call that a driving route.

## Current contract evidence

- `QuoteResponse` exposes pickup/dropoff coordinates, road distance and duration,
  but no route geometry.
- `BookingResponse` exposes neither pickup/dropoff nor geometry. Its
  `quotePublicId` ties the accepted Booking to the priced Quote.
- `DriverOfferResponse` exposes pickup/dropoff to the offered Driver, while
  `TrackingResponse` exposes authorized live Driver GPS but no road geometry.
- `OsrmRoutingAdapter` requests `overview=false` and persists only distance,
  duration and provider in `RouteEstimate`. No Backend route-geometry endpoint
  exists in the current pricing, booking, trip or dispatch API controllers.

## Proposed read-only endpoints

1. `GET /api/v1/quotes/{quotePublicId}/route`: only the authenticated CUSTOMER
   who owns that Quote, including after expiry for historical display.
2. `GET /api/v1/bookings/{bookingPublicId}/route`: the authenticated CUSTOMER
   who owns that Booking or its **assigned** DRIVER. A pending offer alone does
   not grant access to this Booking endpoint. For another principal, return the
   existing masked-not-found response; never treat possession of a UUID as
   authorization. The assigned Driver may retrieve the static route while
   handling or reviewing their own trip, subject to the existing history policy.

Both endpoints should return one immutable route snapshot derived from the
Quote accepted by the Booking. The response can use this shape inside the
existing `ApiResponse` envelope:

```json
{
  "sourceQuotePublicId": "uuid",
  "bookingPublicId": "uuid-or-null",
  "availability": "AVAILABLE",
  "geometryFormat": "GEOJSON_LINESTRING",
  "geometry": {
    "type": "LineString",
    "coordinates": [[105.8524, 21.0287], [105.8576, 21.0245]]
  },
  "routingProvider": "OSRM",
  "capturedAt": "2026-10-25T00:00:00Z"
}
```

The coordinate pair order is **[longitude, latitude]** (GeoJSON / WGS84), not
the latitude-longitude order used by GoMove's existing point DTOs. Example
coordinates above illustrate the wire format, **not** a verified road route.
For an older accepted Quote lacking captured geometry, return an authorized
`UNAVAILABLE` response with `geometry: null` and a safe explanation; never
recalculate a different path merely to draw a line. The UI then retains honest
point markers, coordinates and existing trip/payment information.

## Capture, validation and financial invariants

- In a separate Backend milestone, request detailed OSRM geometry from the
  **same routing result** used to issue the Quote, and validate it before
  persisting it immutably with that Quote (a new migration, not a historical
  migration edit). Booking references the accepted Quote's route snapshot.
- Validate a `LineString` with at least two finite points, longitude in
  [-180, 180], latitude in [-90, 90], documented size/vertex limits and
  endpoints consistent with the accepted pickup/dropoff within an explicit
  tolerance. Reject malformed, reversed, empty or oversized provider data.
- Keep existing pricing snapshot, `finalFare`, Quote TTL, idempotent Booking
  consumption and accepted fare unchanged. Geometry retrieval is read-only:
  it does not call OSRM, reprice, refresh a Quote or create a Booking.
- Static route data must not be confused with live Driver GPS or customer
  location sharing. No customer-live-location marker is authorized by this
  proposal.

## Operational and test gates

Serve stored geometry without provider calls on GET. Bound payload size,
rate-limit reads per authenticated principal, and consider a server-side cache
keyed by the immutable Quote snapshot. If conditional requests are used,
perform ownership/assignment checks **before** returning `304`; prevent a
shared client cache from crossing accounts. Provider failure during Quote
creation retains the current routing error behavior; missing legacy geometry
uses the explicit unavailable fallback above.

PostgreSQL/Spring Security integration tests should cover owner and assigned
Driver access, unassigned/pending-offer and unrelated users (masked 404),
completed-trip history, Quote expiry, malformed/oversized or reversed GeoJSON,
lon-lat order, immutable repeat reads, no additional OSRM call or repricing,
and a legacy Quote without geometry. Mobile tests should verify that only an
authorized valid LineString draws a road line and all unavailable/error cases
leave point markers without a fabricated route.

Reverse geocoding is a separate optional contract. Until one exists, use map
style labels and honest “Điểm đón” / “Điểm đến” captions with coordinates in
details rather than invented street addresses.
