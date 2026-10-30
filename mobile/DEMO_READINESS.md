# M4.6 demo readiness and recovery

This is an operator checklist for one Nokia T20 Customer, one Android Emulator
Driver, Spring Boot, PostgreSQL/PostGIS and a locally running Hanoi OSRM. It
does not change Booking, GPS, ETA or CASH rules.

## Check before the demo

From D:/goMove/mobile:

~~~powershell
./tools/check-demo-readiness.ps1
./tools/check-demo-readiness.ps1 -BackendUrl http://127.0.0.1:8080 -OsrmUrl http://127.0.0.1:5000
~~~

The checker reads repo/Git status, Docker and gomove-postgres health, a Hanoi
OSRM route, Spring /actuator/health, ADB transports, the current Wi-Fi IPv4,
and optional Flutter/Java commands. PASS is ready; WARN needs operator review;
FAIL is a blocking demo prerequisite; SKIP means a dependent check could not
run. Exit code 1 means at least one FAIL. It does not start Docker, ADB, an
emulator or Backend. Run it again after fixing a failed prerequisite. Its
current branch default is feature/mobile-demo-readiness; use -ExpectedBranch
on a later personal branch. Service URLs must be local loopback origins.

## Focused recovery

| Symptom | Inspect | Reversible recovery |
| --- | --- | --- |
| Docker Desktop stopped | docker version | Start Docker Desktop manually; wait for its Engine. The checker never starts it. |
| PostgreSQL missing/unhealthy | docker compose ps; docker inspect gomove-postgres | On this machine only, run docker compose up -d postgres from the repo root; wait for healthy. Inspect logs before changing configuration. Never run down -v to troubleshoot. |
| OSRM unavailable | Test-NetConnection 127.0.0.1 -Port 5000; route DryRun | Start the team's existing local Hanoi OSRM process/data; verify a route. Do not replace its data or draw a straight-line route. |
| Backend port 8080 unavailable | Test-NetConnection 127.0.0.1 -Port 8080 | Start the existing Backend manually after DB and OSRM are ready. Check its console for the actual startup failure. |
| Backend health not UP | Invoke-RestMethod http://127.0.0.1:8080/actuator/health | Inspect Spring logs and dependencies; keep the existing local JWT secret. Do not generate a replacement for a transient failure. |
| Driver emulator absent | adb devices -l | Start one emulator manually, wait for device state, then select its actual serial. No second emulator is needed. |
| Nokia offline in ADB | adb devices -l | Reconnect USB or re-pair wireless debugging on the tablet. Confirm the prompt on the device. |
| Wireless debugging IP/port changed | Tablet wireless debugging screen | Read its current IP and port, then adb connect CURRENT_IP:CURRENT_PORT. This is an ADB transport address, separate from the Backend URL. |
| Duplicate ADB transports | adb devices -l | Choose the intended serial with flutter devices and flutter run -d SERIAL; disconnect only a verified unwanted TCP transport with adb disconnect SERIAL. Do not reset the whole ADB server by default. |
| flutter run cannot select device | flutter devices; adb devices -l | Wait for device authorization; pass the exact serial with -d. Reconnect only that transport if needed. |
| Nokia ADB works but Backend fails | Test-NetConnection ASUS_LAN_IP -Port 8080; tablet browser to http://ASUS_LAN_IP:8080/actuator/health | Find the current ASUS Wi-Fi IPv4 using the checker or Get-NetIPAddress, ensure tablet and PC can reach each other, check Windows firewall and Backend bind settings. Build/run the tablet app with API_BASE_URL=http://ASUS_LAN_IP:8080. ADB Wi-Fi IP is not the Backend IP. |
| Driver GPS lacks fresh samples | Driver foreground, permissions, emulator location; existing debug GPS logs | Grant foreground precise location, confirm Android location service and a current provider fix. The simulator writes the emulator provider only; ADB OK does not prove a Backend update. |
| ETA stale or unavailable | Customer GPS text, Backend health, OSRM, Driver latest sample | Wait for a fresh authorized Driver sample and the server's 15 s refresh window. A stationary endpoint hold may still be rejected by anti-replay; do not loosen freshness/accuracy/50 m rules. |
| Customer realtime disconnected | Customer connection label; Backend /ws reachability | Reopen the active Booking from the same account and let the existing client reconnect/reconcile via REST. Do not create a second STOMP connection. |
| Map tiles blank | Network access to configured style/tiles; attribution | Keep coordinate entry and status/CASH flow usable; check approved MAP_STYLE_URL connectivity and provider availability. Do not change Booking data or remove attribution. |
| Driver operating state unknown while loading | Driver screen and API reachability | Wait for the authorized state fetch; on failure inspect network/session then reopen the screen. Do not infer ONLINE or mutate DB. |

## Repeatable Nokia + Emulator smoke test

1. Run the checker; start any missing local services manually and rerun it.
2. Connect Nokia over its current ADB Wi-Fi address; launch/reopen the Customer
   build with the ASUS **LAN** IPv4 Backend URL. Start one Driver emulator with
   its own real-mode app and account.
3. DryRun the pickup route in tools/README.md. Place emulator GPS at the
   printed OSRM-snapped start **before** making Driver ONLINE.
4. Confirm approved Driver, eligible active vehicle and fresh GPS. Customer
   selects real pickup/dropoff, receives a Quote, and explicitly confirms one
   Booking. Driver accepts the real offer within its server lease.
5. Verify pickup ETA. Run the pickup simulator with explicit opt-in; observe
   newer authorized marker coordinates and road ETA. The Customer may pan/zoom;
   Find Driver recenters only on demand.
6. Driver manually selects Arrived, Onboard and Start. Verify destination ETA.
   DryRun then run the destination segment. Optional endpoint hold is 1-180 s.
   Observe whether stationary emulator writes actually yield fresh Backend GPS;
   accept the normal stale/unavailable UI if they do not.
7. Driver manually completes. Customer sees COMPLETED with live GPS/ETA hidden.
   CASH remains PENDING. Driver confirms physical collection in the existing
   UI; verify server-confirmed PAID and Driver release.

Never fabricate Booking, payment or Driver state. Ctrl+C stops a running route;
it leaves the emulator at its last simulated GPS fix. Device E2E needs direct
observation and is not implied by script tests or OSRM DryRun.

## Existing optional marker motion

The Customer map already gates its 300 ms, three-write marker easing behind
GOMOVE_EXPERIMENTAL_MARKER_INTERPOLATION (default false). It accepts only newer
authorized positions, requires a recent sample within the existing gap/age,
distance and speed bounds, honors reduced motion, never extrapolates, and does
not recenter the camera per GPS fix. It removes the Driver marker on completed
or invalidated tracking and adds no connection. For a debug Customer build:

~~~powershell
flutter build apk --debug --dart-define=MOCK_ENABLED=false --dart-define=API_BASE_URL=http://ASUS_LAN_IP:8080 --dart-define=GOMOVE_EXPERIMENTAL_MARKER_INTERPOLATION=true
~~~

On Nokia, compare marker smoothness, manual pan/zoom, native MapLibre load,
battery/CPU and reduced-motion behavior against the default build. Do not
enable this flag by default or treat presentation motion as new GPS evidence.

## Deferred milestones (documentation only)

- Driver-search radar: a subtle pickup visual only while the Backend reports
  SEARCHING_DRIVER; stop on assignment/cancel/failure, show no invented Driver,
  support reduced motion and a clear accessible status.
- Identity cards: after real assignment, show only Backend-authorized Driver
  name/vehicle/plate and contact if available; Driver sees only necessary
  Customer/pickup/dropoff/fare data. Review API contracts and privacy first.
- Post-trip rating: server-backed Customer-owned 1-5 stars for eligible
  completed Bookings, durable deduplication, concurrency/abuse tests and
  verified aggregates. No rating API or UI is part of M4.6.
