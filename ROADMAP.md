# GoMove roadmap

Core Booking → Dispatch → Trip → CASH remains the priority before a broad visual redesign.

| Milestone | Scope | Status |
| --- | --- | --- |
| M4.6 | Demo readiness, GPS stability and team local setup | Completed |
| M5-Participant | Authorized Customer, Driver and vehicle information | Completed (`46ace8f`) |
| M5.1 | Real place/address search and display | Completed (`cec41f9`) |
| M5.2 | Trip history, trip details and Customer receipts | Completed (`1cc65d2`) |
| M5.3 | Cancellation, notifications, connection failures and abnormal states | Current milestone |
| M5.4 | Admin approval and account/activity management | Planned |

M5.4 financial follow-up: V13 creates a CASH `PENDING` row when each Booking is created, including Bookings later `CANCELLED` or `NO_DRIVER_AVAILABLE`. For these terminal outcomes it is an uncollected placeholder, not a collectible fare, `PAID` receipt, refund, or commission debt. CASH settlement already requires a `COMPLETED` Booking. Define an explicit void/not-collected representation and admin visibility in a new migration before changing accounting; do not reinterpret those existing `PENDING` rows as paid.

Later improvements: genuine Backend-driven driver-search radar animation; post-trip Driver ratings (1–5 stars); a broader UI/UX redesign inspired by Grab, Be and GoMove with blue/white and blue-violet identity, map-first screens, bottom sheets and polished transitions.
