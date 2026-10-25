# GoMove Motion Design — proposed M4.4 specification

Status: **M4.4A implemented; M4.4B remains a proposal**. The three
user-provided MP4 references were reviewed as motion/visual examples. The
timings below are **GoMove design targets**, not copies of their brand,
implementation, easing curves or simulated data. Timestamps in the observation
notes are approximate positions in the clips, not proof of backend behavior.

M4.4A implementation note (2026-10-23): Shared Flutter motion tokens and
reduced-motion behavior now cover auth, Customer selection/Quote/Booking status,
Driver offers/trip status and server-confirmed CASH acknowledgement. MapLibre
still receives direct ordered marker updates; sheets, route drawing and marker
interpolation remain M4.4B. `flutter analyze --no-pub` passed and
`flutter test --no-pub` passed 226 tests. The real-mode debug APK build did not reach
compilation because Gradle reported `Unable to establish loopback connection`;
dual-emulator visual/performance validation is still outstanding.

## What the three videos actually show

| Reference | Observed sequence (approximate clip times) | GoMove interpretation / limit |
| --- | --- | --- |
| `3ff5d39c…mp4` — Parcel, 19.8 s | 0.5–5.3 s white splash with courier/abstract line movement and a logo reveal; 5.8–6.8 s illustrated login header and rounded form appear in layers; 13.5–15.4 s login is blurred/dimmed behind a centered signing-in illustration; 15.5–15.9 s home is revealed | Use one-shot auth feedback and layered card entrance, but do not delay auth or copy the courier/brand. The clip does **not** show a multi-page onboarding carousel or a proven shared-element transition. |
| `2281f343…mp4` — dark ride-hailing, 21.1 s | 0–2.7 s pickup/destination and vehicle choice over a dimmed sheet; 2.8–4.1 s map and “Finding your driver” sheet; ~4.1–4.2 s shorter driver-arriving card; ~8.6–8.8 s swipe CTA; 9–16 s lower trip-progress sheet, fast ETA/progress changes and moving map/marker; ~16.0–16.2 s completion card | Adopt sheet hierarchy and truthful state-card replacement, not the dark branding, customer swipe-to-start, accelerated ETA or automatic camera following. The visible line may merely be uncovered by a shrinking sheet: this clip does **not** prove an animated route drawing. |
| `89244908…mp4` — food delivery, 29.8 s | ~1.0–1.5 s Cart→Checkout horizontal page move; ~3.9–4.3 s address-map push and ~5.3–5.6 s return; ~7.4–8.5 s voucher sheet up/down; ~9.3–11.6 s confirm dialog then button spinner; ~11.7–12.0 s checkout reveals map/tracking sheet; a route appears almost instantly around 12.2 s, **not** progressively drawn; 13.8–17.8 s successive preparation/pickup/on-the-way cards; 16–24.6 s courier marker/map move; ~24.7–25.0 s delivered card | Use confirmation-to-tracking continuity, draggable details and ordered marker updates. Do not fabricate place names, courier positions, route, distance, ETA, or a paid state. Some sheet motion is visibly caused by a user drag, not an automatic transition. |

All three are desktop recordings of a phone simulator; their ending TikTok
cards are outside the app demonstration. Neither the true GPS/route/payment
source nor the exact easing, Flutter implementation or Android/MapLibre
performance can be established from pixels alone. Shared-element Hero motion
was **not** clearly observed in these clips; any GoMove Hero below is an
independent, optional proposal.

## Intent and non-negotiable boundaries

Motion should make a state change legible, not make a ride appear to advance
before the server says it has. Keep the M4.3 light GoMove palette and readable
Vietnamese labels; do not copy reference branding or adopt a dark map merely
because a reference has one. Do not add route lines: the current Quote supplies
distance and duration but no route geometry. No animation may create a Booking,
driver assignment, GPS sample, payment result, or authenticated session.

The existing Cubits, repositories, Backend responses and security checks remain
authoritative. Quote `finalFare`, `expiresAt`, pending Booking intent and
idempotency key govern the CTA. An offer is not an assignment. `COMPLETED +
CASH PENDING` is not `PAID`. GPS is shown only for an authorized active trip;
completion, logout and account/session replacement remove it immediately.

MapLibre is a native platform view. Its widget identity, layout slot, style and
controller must stay stable during Flutter card/sheet animation. Never wrap the
map in `Hero`, `AnimatedSwitcher`, `AnimatedSize`, blur or a frame-by-frame
opacity/transform effect; never recreate it per frame. Camera movement remains
limited to the initial authorized GPS fix and explicit **Xem 2 điểm** / **Tìm
tài xế** actions. Do not resume auto-follow after a user pans or zooms.

## Proposed motion tokens

| Purpose | Duration | Curve / behavior | Limit |
| --- | ---: | --- | --- |
| Touch acknowledgement, selected chip | 100–160 ms | `Curves.easeOutCubic` | Scale at most 0.98→1; no repeated pulse |
| Error/help text or small content swap | 160–200 ms | `Curves.easeInOutCubic` | Keep text and semantics readable throughout |
| Card enter / server-confirmed status replacement | 220–260 ms | enter `easeOutCubic`, exit `easeInCubic` | Move at most 8–16 logical px |
| Page forward / back | 280 / 220 ms | `easeInOutCubic` / `easeInCubic` | Fade + at most 16 px slide; no security delay |
| Sheet open / user-release snap | 300 / 280 ms | `easeOutCubic`; critically damped feel | No overshoot over CTA or map controls |
| Confirmed GPS marker move, optional M4.4B | 250–400 ms maximum | linear between *two accepted fixes* | End exactly at newer fix; never predict onward |
| Confirmed CASH `PAID` acknowledgement | 240 ms | `easeOutCubic` | One check/color change, no confetti or optimistic success |

These are design targets, not backend timers. The existing Quote 60-second TTL,
15-second offer lease, 5-second Customer REST reconciliation and 9-second Driver
GPS interval must not be shortened, delayed or represented by fabricated
intermediate state. Countdown text is derived from server deadlines and wall
clock; an animated progress ring, if used, is secondary and is not authority.

Prefer Flutter's built-in `AnimatedSwitcher`, `AnimatedContainer`,
`AnimatedOpacity`, `AnimatedScale`, `TweenAnimationBuilder`, `FadeTransition`,
`SlideTransition`, `PageRouteBuilder` and `DraggableScrollableSheet`. Use a
controller only for a gesture or a coordinated transition that an implicit
widget cannot express. For a custom spring, start near critical damping
(`mass: 1`, `stiffness: 300`, `damping: 35`) and verify its actual settling in
tests; do not use elastic/bounce curves for money, acceptance or location.
There is no demonstrated need yet for `flutter_animate`, `animations`, Rive or
Lottie, so this proposal adds none and recommends no package versions.
`pubspec.yaml` declares Dart `>=3.3.0 <4.0.0` and Flutter `>=3.19.0`;
the local Flutter cache reports Flutter 3.47.5 / Dart 3.13.4. Before coding,
verify every chosen built-in API against the declared minimum SDK as well as
the installed SDK. Any future third-party package proposal requires a concrete
unmet interaction need, version compatibility check and measured cost.

## Journey choreography

1. **Splash → login or role home.** Retain the splash while `AuthBloc`
   determines the session. Once it resolves, fade/slide the destination in;
   never hold an authenticated or logout transition to finish decorative motion.
   A registration/login card can enter once (no perpetual logo loop).
2. **Choose pickup/dropoff.** The selected chip and matching coordinate card
   respond within 160 ms; an 8 px card emphasis explains which point changed.
   Map markers still update only after a valid
   selection; manual coordinates remain equally available when tiles fail.
   Avoid implying that coordinates are verified street addresses.
3. **Quote → Booking.** Reveal the server fare card once, with a 220 ms fade
   and slight rise. The fare never counts up from a made-up amount. Expiry
   switches to a clear warning immediately at `expiresAt`; disable ordinary
   confirmation there, while retaining the existing same-intent retry path.
   Show loading only for the actual Booking request. Transition to Booking
   Status only after `BookingCubit` has a confirmed Booking; an uncertain
   network result remains the pending-intent UI, not a success animation.
4. **Searching → Driver Assigned → Trip Active.** Replace status text and
   progress highlight only after `BookingStatusCubit` confirms the new state.
   Reveal driver details only when authorized data exists. Distinguish
   `DRIVER_ACCEPTED`, `DRIVER_ARRIVED`, `PASSENGER_ONBOARD` and `IN_PROGRESS`
   with one non-looping card transition; never animate a fictitious road path.
5. **Driver offer → acceptance.** Enter the offer card and server-deadline
   countdown without affecting accept/reject eligibility. Acceptance remains
   visually pending until `DriverCubit.acceptedOffer` arrives; expired,
   duplicate or failed offers exit to an honest error/refresh state.
6. **Trip completion and CASH.** On `COMPLETED`, remove live GPS without a fade
   that temporarily exposes it. Keep CASH `PENDING` visible. Driver's explicit
   cash confirmation dialog stays required; only server-confirmed `PAID`
   changes the receipt/customer card, with a brief one-shot check animation.

### Sheets, cards and shared elements

M4.4A animates existing cards in place; it does **not** restructure the map
page. M4.4B may prototype a sheet for route/coordinate details or trip details
as a Flutter overlay above a stable map slot. Use `DraggableScrollableSheet`
only where its provided scroll controller can own the sheet content, with
bounded min/initial/max extents and a visible drag handle. Prefer at most two
snap positions; preserve access to manual coordinate fields and CASH controls
on a 320 px viewport and with the keyboard open. Let the gesture follow the
finger; snap after release, not while the user drags. Programmatic sheet changes
must not recenter, resize or remount MapLibre. If that invariant cannot be
tested, retain the current scroll/card layout.
Swipe is for revealing or dismissing presentation detail, not for creating a
Booking, accepting an offer, ending a trip or confirming physical cash receipt;
those actions retain their explicit guarded controls and server responses.

Use a shared-element `Hero` only for a small **Flutter-only** visual that exists
on both routes (for example the confirmed Quote fare/vehicle emblem and the
accepted Booking summary), with a unique quote-scoped tag and a widget test for
forward/back and session replacement. Do not Hero the map, GPS marker, entire
booking card, personal data, or a speculative fare. A simple page fade/slide is
the fallback when continuity or native-view stability is uncertain.

### Live marker policy

The current `CustomerTripTrackingMap` already rejects invalid or non-newer
fixes and updates one native circle. That direct update is the default M4.4A
behavior. A brief status-card acknowledgement may fire **only** when `updatedAt`
strictly advances; a retained fix after REST returns null must not keep
pulsing. Text always shows the confirmed sample and its actual timestamp.

M4.4B may evaluate visual interpolation only between two valid, authorized,
strictly ordered and fresh fixes for the same Booking/session. Start at the
previous confirmed marker, finish at the newer confirmed coordinate within
400 ms, cap native annotation writes (initial experiment: 10/s), and cancel or
snap on a newer fix, large jump, stale gap, app pause, style reload, disposal,
`COMPLETED`, logout or account switch. The interpolated point is *display-only*:
never publish/store it, label it as a GPS sample, draw a road line through it,
or use it for a camera target. If dual-emulator profiling shows churn or
jank, keep the current one-update-per-fix behavior.

## Reduced motion and accessibility

Honor the platform's disable/reduce-motion request. Suppress spatial movement,
spring and decorative halo; use an immediate switch or at most an 80 ms fade.
Do not suppress loading, error, expiry or payment **meaning**. Keep a textual
status and timestamp, readable focus order, touch targets and live-region
announcements; avoid flashing, looping attention effects and animation-only
color cues. Android's “Remove animations” is reflected by Flutter's
`MediaQueryData.disableAnimations`; explicit custom animation must check it.
Flutter documents iOS reduced motion separately, so verify that platform path
before expanding beyond Android. Do not assume overriding `MediaQuery` alone
changes framework-managed controllers.

## File-by-file implementation plan (future work, not done here)

| File | Proposed change | Phase |
| --- | --- | --- |
| `lib/core/theme/app_motion.dart` (new) | Central duration/curve tokens and reduced-motion decision; no dependency | A |
| `lib/core/theme/app_theme.dart` | Keep M4.3 colors/type; use tokens only where theme-level feedback is helpful, not a global map-affecting route transition | A |
| `lib/features/auth/presentation/screens/splash_screen.dart` | One-shot entry and auth-result page transition; never animate an unresolved session as success | A |
| `lib/features/auth/presentation/screens/login_screen.dart` | Form/error/loading micro-motion without changing token lifecycle | A |
| `lib/features/auth/presentation/screens/register_screen.dart` | Form/error micro-motion and accessible keyboard behavior | A |
| `lib/features/auth/presentation/screens/role_home.dart` | Preserve logout `pushAndRemoveUntil`; no shared element survives session loss | A (guard/test) |
| `lib/features/customer/presentation/screens/customer_home_screen.dart` | Selection/card/loading feedback and confirmed active-Booking entry; preserve account key, manual fallback and pending intent | A |
| `lib/features/customer/presentation/screens/customer_map_canvas.dart` | Keep native map fixed; at most Flutter overlay feedback after valid point selection, no animated map parent | A (guard), B (sheet experiment) |
| `lib/features/customer/presentation/screens/quote_review_screen.dart` | Server-fare reveal, expiry/error/submit transitions; no client fare recomputation or duplicate POST | A |
| `lib/features/customer/presentation/screens/booking_status_screen.dart` | Reuse existing 250 ms status switch; animate progress/CASH card only for confirmed transitions; preserve stable map child index | A |
| `lib/features/customer/presentation/widgets/customer_trip_tracking_map.dart` | Keep direct ordered native-circle update; optional bounded visual interpolation only if B profiling passes | A (guard), B (experiment) |
| `lib/features/driver/presentation/screens/driver_home_screen.dart` | Offer-card/status feedback keyed to server offer and expiry, not optimistic acceptance | A |
| `lib/features/driver/presentation/screens/driver_trip_screen.dart` | Confirmed trip-state and receipt-card feedback; CASH dialog/PENDING semantics unchanged | A |
| `lib/features/customer/presentation/bloc/booking_cubit.dart`, `booking_status_cubit.dart`, `quote_cubit.dart` | No behavior change planned; retain expiry, idempotency, REST/STOMP reconciliation and privacy gates | A/B guard |
| `lib/features/driver/presentation/bloc/driver_cubit.dart`, `driver_trip_cubit.dart` | No behavior change planned; retain offer, GPS fallback and CASH authority | A/B guard |
| `lib/features/trip/data/trip_realtime_client.dart` | No transport/auth change planned; continue validating current session and ordered updates | A/B guard |
| `test/features/auth/auth_motion_test.dart` (new) | Page transition, logout/session replacement and reduced-motion widget tests | A |
| `test/features/customer/customer_home_recovery_test.dart` | Selection feedback, account isolation and no duplicate Quote/Booking calls | A |
| `test/features/customer/quote_review_screen_test.dart` | Fare/expiry/pending-intent motion with fake clock | A |
| `test/features/customer/customer_map_canvas_test.dart` | Native-map mount count and tap/fallback behavior during card motion | A/B |
| `test/features/customer/customer_trip_tracking_test.dart` | Status sequence, completed GPS removal, CASH PENDING→PAID | A/B |
| `test/features/customer/customer_trip_tracking_map_test.dart` | Ordered native-marker updates, no implicit recenter or remount | B |
| `test/features/driver/driver_flow_test.dart`, `driver_trip_test.dart` | Offer deadline, confirmed acceptance, status and CASH feedback | A |
| `test/features/trip/trip_realtime_client_test.dart` | Existing stale/session/unauthorized event guards stay green | A/B guard |

## Prioritized delivery and gates

**M4.4A — low-risk continuity first.** Establish baseline screenshots/FPS and
motion tokens; add reduced-motion behavior, auth/page and chip/card transitions,
Quote/Booking/Driver status and CASH confirmation feedback. Keep map updates
direct, no sheet restructuring, no new dependencies. Gate: `flutter analyze`,
`flutter test`, widget tests at 320 px/text scaling and reduced motion, no extra
Booking/Trip API calls, no map remount on ordinary polling, two-emulator manual
Golden Path. If the Windows Gradle loopback issue still blocks APK compilation,
report it separately rather than claiming device validation.

**M4.4B — measured map/sheet work.** Prototype a sheet overlay without moving
the map in the element tree. Measure and retain only if accessible and stable.
Then trial bounded marker interpolation behind a presentation-only toggle;
ship only if strict ordering/privacy tests and performance gates pass. Otherwise
ship the direct marker update and static cards. No animated road route until an
authorized backend route geometry contract exists.

## Risks and practical verification plan

| Risk | Check / mitigation |
| --- | --- |
| Native platform-view remount, tile reload or annotation churn | Widget test counts map creates/disposes across loading/status/CASH rebuilds; manual pan/zoom remains unchanged after newer fix |
| Out-of-order, stale or retained GPS looks live | Fake-clock tests for duplicate/older/future/late fixes, REST↔STOMP race and session replacement; no motion on retained timestamp |
| GPS leak after completion or logout | Verify map/marker removed immediately and no old-session animation callback survives |
| Fake success or duplicate Booking | Assert animation follows confirmed Cubit state; quote expiry boundary, pending intent and Idempotency-Key tests remain green |
| CASH misleadingly appears paid | Test `COMPLETED + PENDING`, confirm dialog cancellation, server failure, and only then `PAID` receipt animation |
| Small screen, keyboard, large text, reduced motion | Widget tests at 320 px, text scaling and platform disable-motion; sheet CTA/focus/semantics remain reachable |
| Dual Android 14 emulator RAM/CPU contention | Warm both apps, compare M4.3 baseline with M4.4 under the same host load and trip sequence; watch map mount count, CPU, RAM and frame timing |

Run `flutter analyze --no-pub` and `flutter test --no-pub` after each phase.
Use deterministic `tester.pump(Duration(...))` and fake clocks for widget
animation/deadline tests; no real 15- or 60-second waits and no fake production
GPS. For the two emulators, drive real authenticated Customer/Driver flows,
including manual ADB location changes, REST fallback, completion and CASH.
Record three warmed trials per scenario, both emulator serials, build mode,
host RAM, and baseline/after measurements. Android's
`adb -s <serial> shell dumpsys gfxinfo com.example.gomove_mobile framestats`
and `dumpsys meminfo` can compare the dual-emulator setup, but those timings
are not a substitute for Flutter UI/raster profiling. Flutter's documentation
says mobile **profile mode is disabled on emulators** and debug timing is not
representative; use a physical Android device in profile mode with DevTools
Performance for the authoritative 60 Hz target (about 16.7 ms/frame). Proposed
gate: no more than 10% regression in dual-emulator janky-frame count/peak app
memory versus M4.3 under the same conditions, and on a physical profile run
90th/95th percentile UI and raster times below a frame budget where feasible;
investigate any repeated >33 ms frames. These are acceptance targets, not
results already measured.

## Sources to re-check during implementation

- Flutter [implicit animations](https://docs.flutter.dev/ui/animations/implicit-animations), [AnimatedSwitcher](https://api.flutter.dev/flutter/widgets/AnimatedSwitcher-class.html), [Hero](https://api.flutter.dev/flutter/widgets/Hero-class.html) and [DraggableScrollableSheet](https://api.flutter.dev/flutter/widgets/DraggableScrollableSheet-class.html).
- Flutter [disableAnimations](https://api.flutter.dev/flutter/widgets/MediaQueryData/disableAnimations.html) and [performance profiling/build modes](https://docs.flutter.dev/perf/ui-performance).
- Android [gfxinfo framestats](https://developer.android.com/tools/dumpsys).
