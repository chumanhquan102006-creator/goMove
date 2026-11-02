# GoMove roadmap

Core Booking → Dispatch → Trip → CASH remains the priority before a broad visual redesign.

| Milestone | Scope | Status |
| --- | --- | --- |
| M4.6 | Demo readiness, GPS stability and team local setup | Completed |
| M5-Participant | Authorized Customer, Driver and vehicle information | Completed (`46ace8f`) |
| M5.1 | Real place/address search and display | Completed (`cec41f9`) |
| M5.2 | Trip history, trip details and Customer receipts | Completed (`1cc65d2`) |
| M5.3 | Cancellation, notifications, connection failures and abnormal states | Completed (`a00b500`) |
| M5.4 | Admin approval and account/activity management | Completed (`d95875c`) |
| M5.5 | Map-first UI, motion, verified Driver ratings, GoPoints and quality review | Current milestone |

M5.4 financial treatment: V17 converts uncollected CASH placeholders on `CANCELLED` or `NO_DRIVER_AVAILABLE` Bookings to immutable `VOID`. Only a `COMPLETED` Booking with `PENDING` CASH is counted as collectible. `VOID` is neither a paid receipt, refund nor commission debt. Dashboard counters are lifetime totals at query time: Customers are accounts currently in the CUSTOMER role; Drivers are registered Driver profiles; approval and operating counts use current Driver status; active Bookings are all nonterminal statuses; paid CASH counts confirmed payments. Account management is read-only in M5.4. Admin credentials must be provisioned by an explicitly controlled development procedure; public registration never creates an ADMIN account.

M5.5 adds optional 1–5 star ratings for completed, Customer-owned Bookings. Each accepted rating has one immutable GoPoints event (+10/+5/0/−5/−10); the visible balance is floored at zero and never changes CASH or commission. A configurable quality policy flags a Driver after at least 10 verified ratings when the recent average is below 3.0. Admin review and Driver dispute are recorded in append-only actions. A dismissed case needs a full new recent window of ratings before another case can be opened. The Customer search radar is driven by the authorized `SEARCHING_DRIVER` state and actual pickup coordinates. GPS marker motion only interpolates between newer validated samples, stops on lifecycle/privacy changes and never updates the map camera. Driver Home reads paid-trip cash totals and commission from the existing authorized summary API; the displayed after-commission amount is a read-only calculation, not a payout or remittance record.

M5.5 still needs a manual Customer/Driver/Admin device pass before release. Android native marker styling, radar frame rate on Nokia T20 and the two-device handoff are not proven by widget tests alone.
