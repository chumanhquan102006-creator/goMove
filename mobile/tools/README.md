# M4.5B: development-only GPS route demonstration

`demo-gps-route.ps1` moves **one Android Emulator's location provider** along
the GeoJSON road route returned by the local OSRM server. The Driver app still
reads that location through Geolocator and sends it through its existing
authenticated GPS path. The Customer still reads authorized tracking and ETA
from the Backend. This tool does not call Backend APIs, change Booking or trip
status, confirm CASH, or run when GoMove starts. Its coordinates are simulated.

Use PowerShell from `D:\goMove\mobile`. Keep the Driver app in the foreground
with location permission granted. Use the emulator serial printed by ADB, not a
physical tablet serial. The Nokia T20 is the Customer device.

```powershell
Set-Location D:\goMove\mobile
adb devices -l
```

The command below checks OSRM geometry, arguments, sample count and estimated
duration **without changing any device location**. DryRun does not verify that
the supplied serial is connected; the live run verifies the emulator. These
Hanoi coordinates are example inputs only, not application defaults:

```powershell
.\tools\demo-gps-route.ps1 -DeviceId emulator-5554 `
  -StartLatitude 21.0288 -StartLongitude 105.8526 `
  -DestinationLatitude 21.0298 -DestinationLongitude 105.8440 `
  -SpeedKmh 24 -IntervalSeconds 3 -OsrmBaseUrl 'http://127.0.0.1:5000' -DryRun
```

The OSRM road may start or end at a snapped point away from the requested
coordinates. Read the first and last snapped coordinates and snap distances in
DryRun output. For this example, a local OSRM check found the first road point
about 125 m from the supplied Driver start. **Before the live demo**, use the
Android Emulator's Extended Controls → Location to place the emulator at the
printed first road point, avoiding an initial jump. Do not invent a straight
connector from the requested point to the road. If the road snap is unsuitable,
choose a closer valid starting coordinate and run DryRun again.
When the requested start is more than 50 m from the snapped road start, the
live command also requires `-ConfirmSnappedStart`. Add it **only after**
prepositioning the emulator at the printed snapped first coordinate; the switch
does not move or verify the emulator's current position.

## Pickup segment

After DryRun, preposition the emulator at the printed snapped road start
**before** making the approved Driver ONLINE or creating the Booking. This
prevents a one-time marker jump when the accepted trip first becomes visible.
Then make the Driver ONLINE with an eligible vehicle and fresh GPS.
Have the Customer create a real Booking and the Driver accept the real offer
within its server lease. Check that the Customer has a pickup ETA. Then opt in
explicitly to the location simulation:

```powershell
.\tools\demo-gps-route.ps1 -DeviceId emulator-5554 `
  -StartLatitude 21.0288 -StartLongitude 105.8526 `
  -DestinationLatitude 21.0298 -DestinationLongitude 105.8440 `
  -SpeedKmh 24 -IntervalSeconds 3 -OsrmBaseUrl 'http://127.0.0.1:5000' `
  -ConfirmSnappedStart -IUnderstandThisSimulatesGps
```

Watch the Customer marker and approximate road ETA. The tool stops at the last
road point; it **does not** press Arrived. After checking the final position,
press Arrived and Onboard in the Driver app, then manually press Start.

## Destination segment

Run a new DryRun first. Its requested start is the pickup point; check its
printed snapped first point against the emulator's current location. If this
segment's start snap also exceeds 50 m, preposition the emulator and add
`-ConfirmSnappedStart` to its live command.
With the current local Hanoi OSRM data, the pickup segment's last road point
and destination segment's first road point match; always verify your own DryRun
before proceeding.

```powershell
.\tools\demo-gps-route.ps1 -DeviceId emulator-5554 `
  -StartLatitude 21.0298 -StartLongitude 105.8440 `
  -DestinationLatitude 21.0348 -DestinationLongitude 105.8290 `
  -SpeedKmh 24 -IntervalSeconds 3 -OsrmBaseUrl 'http://127.0.0.1:5000' -DryRun

.\tools\demo-gps-route.ps1 -DeviceId emulator-5554 `
  -StartLatitude 21.0298 -StartLongitude 105.8440 `
  -DestinationLatitude 21.0348 -DestinationLongitude 105.8290 `
  -SpeedKmh 24 -IntervalSeconds 3 -OsrmBaseUrl 'http://127.0.0.1:5000' `
  -IUnderstandThisSimulatesGps
```

The tool stops at the destination road point. The Driver must manually press
Complete. CASH remains `PENDING` until the Driver explicitly confirms physical
collection through the existing UI; then verify `PAID` and Driver release.

### Optional stationary endpoint hold (M4.6)

Add `-HoldAtDestinationSeconds 60` to either **live** segment command when the
operator needs time to inspect the final position. The default is `0`, so
existing 81/89 road updates and stop behavior remain unchanged. The accepted
range is 1–180 seconds; the script writes the **same final snapped coordinate**
to the same verified emulator every 9 seconds, with a final write at the chosen
duration if needed. DryRun reports the hold but never emits GPS. Ctrl+C or an
ADB failure stops the hold immediately; it never runs as a background service.

```powershell
.\tools\demo-gps-route.ps1 -DeviceId emulator-5554 `
  -StartLatitude 21.0298 -StartLongitude 105.8440 `
  -DestinationLatitude 21.0348 -DestinationLongitude 105.8290 `
  -OsrmBaseUrl 'http://127.0.0.1:5000' `
  -HoldAtDestinationSeconds 60 -IUnderstandThisSimulatesGps
```

An ADB `OK` confirms only the emulator console write. It does **not** prove
Geolocator sampled a new timestamp, the Driver uploaded it, the Backend stored
it, or ETA remained available. If the existing anti-stale or duplicate-location
rules reject stationary fixes, leave the Customer's GPS/ETA unavailable state
visible; do not add fake movement or weaken those rules.

## Controls and recovery

- Defaults are 24 km/h and one emulator location update every 3 seconds,
  approximately 20 m per sample. This does not make the Driver app upload every
  sample: its foreground GPS loop is approximately 9 seconds, and Backend ETA
  refresh is at least 15 seconds with a 50 m movement threshold. Neither the
  simulation nor the Customer UI counts ETA down locally.
- Press **Ctrl+C** in the PowerShell window to stop. The tool does not leave a
  background GPS process; rerunning it requires a new explicit opt in. Keep the
  Driver trip on its real server-confirmed status until you choose the next UI
  action.
- If ADB disconnects, the script stops. Recheck `adb devices -l`, reconnect
  the **same emulator**, run DryRun, and start a new route from its actual
  current location. Do not restart an old route at a distant first point.
- If OSRM is unavailable or returns an invalid/no route, the script stops
  without a straight-line fallback. Restore the local OSRM service, run
  DryRun again, and inspect its first/last snapped points before opting in.
- If the Customer marker seems stationary, confirm the Driver app is in the
  foreground and its latest GPS sample was sent. The script only changes the
  emulator provider; the app, network, authorization and GPS sampling determine
  which positions reach Backend. The Customer can pan or zoom freely and use
  **Tìm tài xế** to recenter on demand.

Useful read-only recovery checks in PowerShell:

```powershell
adb devices -l
adb -s emulator-5554 get-state
Test-NetConnection 127.0.0.1 -Port 5000
```

If the emulator is absent or `offline`, reconnect it through the Android
Emulator controls and repeat the device checks. If port 5000 is closed,
restore the existing local OSRM process before repeating the route DryRun;
this tool does not start OSRM or fall back to a fabricated route.

The existing optional marker easing can be enabled on a **development**
Customer build with
`--dart-define=GOMOVE_EXPERIMENTAL_MARKER_INTERPOLATION=true`. It remains off by
default, honors reduced-motion settings, and interpolates only between
accepted GPS fixes. It is independent of this script; no app code or second
WebSocket connection is required. For a physical Nokia tablet, build the app
with an `API_BASE_URL` reachable over the laptop's LAN; emulator-only
`10.0.2.2` is not reachable from the tablet.

An optional single Customer debug APK build with the experimental marker
easing enabled (replace the LAN host before running) is:

```powershell
flutter build apk --debug --dart-define=MOCK_ENABLED=false `
  --dart-define=API_BASE_URL=http://YOUR_PC_LAN_IP:8080 `
  --dart-define=GOMOVE_EXPERIMENTAL_MARKER_INTERPOLATION=true
```

Run the standalone mocked tool tests without an emulator or OSRM:

```powershell
.\tools\test-demo-gps-route.ps1
.\tools\test-check-demo-readiness.ps1
```

This checklist and the mocked tests do not constitute Android E2E evidence.

Run `.\tools\check-demo-readiness.ps1` for read-only local environment checks.
It prints PASS/WARN/FAIL/SKIP and exits `1` when a blocking prerequisite fails.
See [demo readiness and recovery](../DEMO_READINESS.md) and
[team local setup](../TEAM_LOCAL_SETUP.md).
