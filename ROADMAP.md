# GoMove roadmap

Core Booking → Dispatch → Trip → CASH remains the functional baseline for the Customer redesign.

| Milestone | Scope | Status |
| --- | --- | --- |
| M4.6 | Demo readiness, GPS stability and team local setup | Completed |
| M5-Participant | Authorized Customer, Driver and vehicle information | Completed (`46ace8f`) |
| M5.1 | Real place/address search and display | Completed (`cec41f9`) |
| M5.2 | Trip history, trip details and Customer receipts | Completed (`1cc65d2`) |
| M5.3 | Cancellation, notifications, connection failures and abnormal states | Completed (`a00b500`) |
| M5.4 | Admin approval and account/activity management | Completed (`d95875c`) |
| M5.5 | Map-first UI, motion, verified Driver ratings, GoPoints and quality review | Completed (`1c733a6`) |
| M5.6 Phase 1 | Premium Customer UI/UX and motion | Completed (`8f3cd55`); Nokia T20 and Emulator E2E passed (project-lead report) |
| M5.6 Phase 2 | Premium Driver UI/UX | Completed (`9677c9b`); device E2E passed (project-lead report) |
| M5.6 Phase 3 | Premium Admin UI/UX | Static code review complete; tester-reported device E2E: 29/29 executed checks passed; Flutter analyze: 0 issues, Flutter tests: 438/438 passed; data-dependent workflows remain untested |

M5.4 financial treatment: V17 converts uncollected CASH placeholders on `CANCELLED` or `NO_DRIVER_AVAILABLE` Bookings to immutable `VOID`. Only a `COMPLETED` Booking with `PENDING` CASH is counted as collectible. `VOID` is neither a paid receipt, refund nor commission debt. Dashboard counters are lifetime totals at query time: Customers are accounts currently in the CUSTOMER role; Drivers are registered Driver profiles; approval and operating counts use current Driver status; active Bookings are all nonterminal statuses; paid CASH counts confirmed payments. Account management is read-only in M5.4. Admin credentials must be provisioned by an explicitly controlled development procedure; public registration never creates an ADMIN account.

M5.5 adds optional 1–5 star ratings for completed, Customer-owned Bookings. Each accepted rating has one immutable GoPoints event (+10/+5/0/−5/−10); the visible balance is floored at zero and never changes CASH or commission. A configurable quality policy flags a Driver after at least 10 verified ratings when the recent average is below 3.0. Admin review and Driver dispute are recorded in append-only actions. A dismissed case needs a full new recent window of ratings before another case can be opened. The Customer search radar is driven by the authorized `SEARCHING_DRIVER` state and actual pickup coordinates. GPS marker motion only interpolates between newer validated samples, stops on lifecycle/privacy changes and never updates the map camera. Driver Home reads paid-trip cash totals and commission from the existing authorized summary API; the displayed after-commission amount is a read-only calculation, not a payout or remittance record.

M5.5 main Android E2E tests were performed. The Admin quality-moderation threshold E2E remains untested. Nokia T20 radar frame rate has not been separately profiled; widget tests cannot establish native map performance.

M5.6 Phase 1 changes presentation only: floating Customer search entry points, a compact draggable booking sheet, secondary manual coordinate entry, clearer vehicle/quote/trip surfaces and reduced-motion-aware feedback. MapLibre remains mounted during ordinary sheet and card animation. Driver/Admin redesign and business logic are outside this phase.

The project lead reports M5.6 Phase 1 E2E passes on Nokia T20 and Android Emulator for Customer Home, full-screen search, sheet gestures, Quote Review, routing and transitions, backend-driven radar and Driver matching, realtime GPS and MapLibre marker movement, Trip lifecycle, CASH PENDING → PAID, and an optional four-star rating with +5 GoPoints.

Future backlog: dedicated, authorized Driver Trip History list. The current Backend exposes a Customer-only Booking history list and an aggregate Driver earnings summary, but no Driver trip-history list API. M5.6 Phase 2 uses the existing earnings summary and current-trip receipt; it does not infer a trip list from local state or Customer endpoints.

M5.6 Phase 3 presents authorized Admin dashboard counters, Driver approvals, read-only accounts, Booking/CASH states and quality cases in a responsive Premium interface. `paidCashPayments` is a count of confirmed CASH payments, not a VND total. The only Admin dashboard money values are collectible completed-trip CASH PENDING and CASH VOID; VOID is not revenue, refund or commission debt. Booking cards expand using Customer/assigned Driver public IDs and creation time already returned by the list API. Quality status filtering uses the existing server parameter; moderation decisions still require notes and authoritative reconciliation, including after a backgrounded in-flight action.

The tester reports 29/29 executed Phase 3 real-device E2E checks passed: Admin Dashboard 6/6; Driver Management 5/5; Accounts, Bookings and CASH 8/8; Quality Moderation UI 4/4; and logout, session and access controls 6/6. Eligible test records were unavailable for Driver approval/rejection, quality case details, quality moderation decisions and the automatic quality-case threshold trigger. These four workflows remain pending dedicated device E2E tests; the UI checks do not establish that their actions passed.

Admin backlog: a dedicated Booking detail API, Booking search or CASH-status filtering, and account edit/disable/role-change operations. The current Admin APIs do not support these controls, so Phase 3 does not display them.
