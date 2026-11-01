# GoMove roadmap

Core Booking → Dispatch → Trip → CASH remains the priority before a broad visual redesign.

| Milestone | Scope | Status |
| --- | --- | --- |
| M4.6 | Demo readiness, GPS stability and team local setup | Completed |
| M5-Participant | Authorized Customer, Driver and vehicle information | Completed (`46ace8f`) |
| M5.1 | Real place/address search and display | Completed (`cec41f9`) |
| M5.2 | Trip history, trip details and Customer receipts | Completed (`1cc65d2`) |
| M5.3 | Cancellation, notifications, connection failures and abnormal states | Completed (`a00b500`) |
| M5.4 | Admin approval and account/activity management | Current milestone |

M5.4 financial treatment: V17 converts uncollected CASH placeholders on `CANCELLED` or `NO_DRIVER_AVAILABLE` Bookings to immutable `VOID`. Only a `COMPLETED` Booking with `PENDING` CASH is counted as collectible. `VOID` is neither a paid receipt, refund nor commission debt. Dashboard counters are lifetime totals at query time: Customers are accounts currently in the CUSTOMER role; Drivers are registered Driver profiles; approval and operating counts use current Driver status; active Bookings are all nonterminal statuses; paid CASH counts confirmed payments. Account management is read-only in M5.4. Admin credentials must be provisioned by an explicitly controlled development procedure; public registration never creates an ADMIN account.

Later improvements: genuine Backend-driven driver-search radar animation; post-trip Driver ratings (1–5 stars); a broader UI/UX redesign inspired by Grab, Be and GoMove with blue/white and blue-violet identity, map-first screens, bottom sheets and polished transitions.
