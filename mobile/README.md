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
