# GoMove Flutter M1

The app defaults to mock authentication for the existing UI tests. For the real Customer flow on a standard Android emulator, run from `mobile/`:

```powershell
flutter pub get
flutter run -d emulator-5554 --dart-define=MOCK_ENABLED=false --dart-define=API_BASE_URL=http://10.0.2.2:8080
```

`API_BASE_URL` may be the server origin or an origin ending in `/api/v1`; it is normalized once. For a remote HTTPS deployment, pass its HTTPS origin instead. `WS_BASE_URL` is accepted for later phases but unused in M1. Do not put credentials or JWTs in dart-defines.

The coordinate fields are editable and prefilled with Hanoi demonstration points; they are not address search or geocoding. OSRM road distance and fare come only from the backend. Quote confirmation uses the backend's `expiresAt` and `finalFare`; local countdown is advisory. After a network timeout, retry the persisted Booking intent with the same idempotency key. The pending-intent card lets the same Customer explicitly abandon it only after considering whether the previous request may have succeeded.

The Android scaffold is generated with Flutter 3.47.5. Internet permission applies to all builds; cleartext HTTP is allowed in debug/profile manifests only for local emulator development. Release remains HTTPS-ready. A running backend, its PostgreSQL and OSRM dependencies, and an existing Customer account are needed for an end-to-end smoke test.

To enter Vietnamese names on the Android emulator, enable Vietnamese in Gboard: open Android Settings → System → Keyboard (or Languages & input) → On-screen keyboard → Gboard → Languages → Add keyboard → Vietnamese. Switch languages with the globe key or by holding the space bar. The registration name field uses the system name keyboard and retains composed/decomposed Vietnamese characters; no app-specific keyboard is needed.

## M2 Driver dispatch demo

Run real mode with the command above. Use a separate Customer and Driver account. A Customer can open **Đăng ký làm tài xế**, submit a real license number to `POST /api/v1/drivers/onboarding`, then must sign out and sign in again to obtain a DRIVER JWT. The resulting profile is PENDING/OFFLINE; the app never self-approves it.

Approval requires an already legitimately provisioned ADMIN account. With that account's own JWT, an authorized operator may call `PATCH /api/v1/drivers/{driverPublicId}/approval-status` with `{"status":"APPROVED"}` using a trusted API client. The `driverPublicId` comes from the onboarding response. Do not put Admin credentials into the Flutter app, share JWTs, or alter PostgreSQL rows manually. There is no public Admin registration or approval UI; if no Admin account is provisioned, the real Driver dispatch demo is blocked at approval.

After approval, sign in as DRIVER, add a matching vehicle, activate it, and press ONLINE. The app uses Android foreground location only: grant location permission, enable device location, and for emulator GPS set a position near the Customer pickup (within the backend's 5 km dispatch radius) in Android Studio **Extended Controls → Location**. The app does not hardcode its GPS position. Approximate permission may reduce eligibility. GPS is uploaded immediately and every 9 seconds while foreground/ONLINE or BUSY; active offers are polled every 2 seconds while foreground/ONLINE with a fresh GPS upload (<30 seconds). Backgrounding stops both loops and does not force BUSY to OFFLINE. Foreground resumption revalidates ONLINE with the server.

The offer card shows the server-provided `expiresAt`; local countdown only disables late taps, and server 409 remains authoritative. Accept/Reject are sent once for the offer UUID. If a response is lost, the app checks authorized Booking tracking and never blindly repeats a decision. A confirmed accept shows the original offer's Booking UUID, coordinates, vehicle type and fare and the server-confirmed BUSY state. That handoff is stored per account and rechecked against tracking on restart. No Driver profile-read or current-assignment-list endpoint exists, so after a fresh start with no saved handoff the current operating status is **Chưa xác định** until a server status response; app-data deletion cannot recover an assignment. Trip transitions, cash and WebSocket tracking are intentionally not part of M2.

For a real dispatch smoke test, start PostgreSQL/PostGIS, Spring Boot with dispatch enabled, and OSRM for Customer Quote. Use two Android emulators or devices with separate accounts. Have the approved Driver ONLINE with an active matching vehicle and fresh GPS near pickup; then have the Customer create a new Booking. Accept the single offer within its 15-second server lease and confirm the Customer Booking transitions to `DRIVER_ACCEPTED`. Without the prerequisite accounts/services this is a checklist, not evidence of an executed end-to-end test.
