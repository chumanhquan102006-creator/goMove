#requires -Version 5.1
<#
.SYNOPSIS
  Development-only GPS route playback for one verified Android Emulator.
.DESCRIPTION
  Reads a local OSRM GeoJSON road route, samples it at a bounded speed, and
  sends each point only to the emulator location provider through ADB. The
  existing GoMove Driver app decides whether to upload a fresh GPS sample.
  Dot-source this file to test its pure functions without running the tool.
#>
[CmdletBinding()]
param(
    [string]$DeviceId,
    [Nullable[double]]$StartLatitude,
    [Nullable[double]]$StartLongitude,
    [Nullable[double]]$DestinationLatitude,
    [Nullable[double]]$DestinationLongitude,
    [double]$SpeedKmh = 24,
    [double]$IntervalSeconds = 3,
    [int]$HoldAtDestinationSeconds = 0,
    [string]$OsrmBaseUrl = 'http://127.0.0.1:5000',
    [switch]$DryRun,
    [switch]$IUnderstandThisSimulatesGps,
    [switch]$ConfirmSnappedStart
)

function Assert-DemoCoordinate {
    param([double]$Latitude, [double]$Longitude)
    if ([double]::IsNaN($Latitude) -or [double]::IsInfinity($Latitude) -or
        [double]::IsNaN($Longitude) -or [double]::IsInfinity($Longitude) -or
        $Latitude -lt -90 -or $Latitude -gt 90 -or
        $Longitude -lt -180 -or $Longitude -gt 180) {
        throw 'Latitude/longitude must be finite and within [-90,90]/[-180,180].'
    }
}

function Format-DemoDecimal {
    param([double]$Value)
    return $Value.ToString('0.0000000000', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-DemoNumber {
    param($Value, [string]$Name)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) {
        throw "OSRM $Name must be a JSON number."
    }
    try { $number = [Convert]::ToDouble($Value, [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { throw "OSRM $Name must be a JSON number." }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        throw "OSRM $Name must be finite."
    }
    return $number
}

function Get-DemoDistanceMeters {
    param([double]$FirstLatitude, [double]$FirstLongitude,
          [double]$SecondLatitude, [double]$SecondLongitude)
    $radians = [Math]::PI / 180.0
    $firstLat = $FirstLatitude * $radians
    $secondLat = $SecondLatitude * $radians
    $deltaLat = ($SecondLatitude - $FirstLatitude) * $radians
    $deltaLon = ($SecondLongitude - $FirstLongitude) * $radians
    $a = [Math]::Pow([Math]::Sin($deltaLat / 2), 2) +
         [Math]::Cos($firstLat) * [Math]::Cos($secondLat) *
         [Math]::Pow([Math]::Sin($deltaLon / 2), 2)
    return 2 * 6371000.0 * [Math]::Atan2([Math]::Sqrt([Math]::Max(0.0, $a)),
                                        [Math]::Sqrt([Math]::Max(0.0, 1.0 - $a)))
}

function ConvertFrom-DemoOsrmRoute {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [double]$StartLatitude, [double]$StartLongitude,
        [double]$DestinationLatitude, [double]$DestinationLongitude
    )
    Assert-DemoCoordinate $StartLatitude $StartLongitude
    Assert-DemoCoordinate $DestinationLatitude $DestinationLongitude
    if ($null -eq $Response -or $Response.code -cne 'Ok' -or
        $Response.routes -isnot [array] -or @($Response.routes).Count -lt 1 -or
        $Response.waypoints -isnot [array] -or @($Response.waypoints).Count -ne 2) {
        throw 'OSRM did not return one usable route and two waypoints.'
    }
    $route = @($Response.routes)[0]
    $geometry = $route.geometry
    if ($null -eq $geometry -or $geometry.type -cne 'LineString' -or
        $geometry.coordinates -isnot [array]) {
        throw 'OSRM route geometry must be a GeoJSON LineString.'
    }
    $pairs = @($geometry.coordinates)
    if ($pairs.Count -lt 2 -or $pairs.Count -gt 8192) {
        throw 'OSRM route must contain 2 to 8192 vertices.'
    }
    $geometryJson = ConvertTo-Json -InputObject $geometry -Depth 12 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($geometryJson) -gt 524288) {
        throw 'OSRM route geometry exceeds 512 KiB.'
    }
    $points = New-Object 'System.Collections.Generic.List[object]'
    foreach ($pair in $pairs) {
        $values = @($pair)
        if ($pair -isnot [array] -or $values.Count -ne 2) {
            throw 'OSRM coordinate must have [longitude, latitude].'
        }
        $lon = ConvertTo-DemoNumber $values[0] 'longitude'
        $lat = ConvertTo-DemoNumber $values[1] 'latitude'
        Assert-DemoCoordinate $lat $lon
        $point = [pscustomobject]@{ Latitude = $lat; Longitude = $lon }
        if ($points.Count -eq 0 -or
            $point.Latitude -ne $points[$points.Count - 1].Latitude -or
            $point.Longitude -ne $points[$points.Count - 1].Longitude) {
            $points.Add($point)
        }
    }
    if ($points.Count -lt 2) { throw 'OSRM route has no movement to simulate.' }
    $roadDistance = ConvertTo-DemoNumber $route.distance 'route distance'
    $roadDuration = ConvertTo-DemoNumber $route.duration 'route duration'
    if ($roadDistance -le 0 -or $roadDistance -gt 100000 -or
        $roadDuration -le 0 -or $roadDuration -gt 86400) {
        throw 'OSRM route distance or duration is outside demo limits.'
    }

    $waypoints = @($Response.waypoints)
    $requested = @(
        [pscustomobject]@{ Latitude = $StartLatitude; Longitude = $StartLongitude },
        [pscustomobject]@{ Latitude = $DestinationLatitude; Longitude = $DestinationLongitude }
    )
    $ends = @($points[0], $points[$points.Count - 1])
    $snaps = New-Object 'System.Collections.Generic.List[double]'
    for ($i = 0; $i -lt 2; $i++) {
        $waypoint = $waypoints[$i]
        if ($waypoint.location -isnot [array] -or @($waypoint.location).Count -ne 2) {
            throw 'OSRM waypoint must contain [longitude, latitude].'
        }
        $wpLon = ConvertTo-DemoNumber (@($waypoint.location)[0]) 'waypoint longitude'
        $wpLat = ConvertTo-DemoNumber (@($waypoint.location)[1]) 'waypoint latitude'
        Assert-DemoCoordinate $wpLat $wpLon
        $reported = ConvertTo-DemoNumber $waypoint.distance 'waypoint snap distance'
        $actual = Get-DemoDistanceMeters $requested[$i].Latitude $requested[$i].Longitude $wpLat $wpLon
        $geometryOffset = Get-DemoDistanceMeters $ends[$i].Latitude $ends[$i].Longitude $wpLat $wpLon
        if ($reported -lt 0 -or $reported -gt 200 -or $actual -gt 200 -or
            $geometryOffset -gt 10) {
            throw 'OSRM snapped a route endpoint too far from the requested point or geometry.'
        }
        $snaps.Add($actual)
    }
    return [pscustomobject]@{
        Coordinates = $points.ToArray()
        RoadDistanceMeters = $roadDistance
        RoadDurationSeconds = $roadDuration
        StartSnapMeters = $snaps[0]
        DestinationSnapMeters = $snaps[1]
        SnappedStart = $ends[0]
        SnappedDestination = $ends[1]
    }
}

function Get-DemoRouteSamples {
    param([Parameter(Mandatory = $true)][object[]]$Coordinates,
          [double]$SpeedKmh = 24, [double]$IntervalSeconds = 3)
    if ([double]::IsNaN($SpeedKmh) -or [double]::IsInfinity($SpeedKmh) -or
        $SpeedKmh -lt 5 -or $SpeedKmh -gt 60 -or
        [double]::IsNaN($IntervalSeconds) -or [double]::IsInfinity($IntervalSeconds) -or
        $IntervalSeconds -lt 2 -or $IntervalSeconds -gt 10) {
        throw 'Demo speed must be 5-60 km/h and interval 2-10 seconds.'
    }
    if ($null -eq $Coordinates -or $Coordinates.Count -lt 2) {
        throw 'At least two road coordinates are required.'
    }
    $lengths = New-Object 'System.Collections.Generic.List[double]'
    $total = 0.0
    for ($i = 0; $i -lt $Coordinates.Count; $i++) {
        Assert-DemoCoordinate $Coordinates[$i].Latitude $Coordinates[$i].Longitude
        if ($i -gt 0) {
            $length = Get-DemoDistanceMeters $Coordinates[$i - 1].Latitude $Coordinates[$i - 1].Longitude `
                $Coordinates[$i].Latitude $Coordinates[$i].Longitude
            $lengths.Add($length)
            $total += $length
        }
    }
    if ($total -le 0) { throw 'Zero-length route has no movement to simulate.' }
    $metersPerSecond = $SpeedKmh / 3.6
    $duration = $total / $metersPerSecond
    if ($duration -lt $IntervalSeconds) {
        throw 'Road route is too short for reasonably spaced GPS updates at this speed and interval.'
    }
    if ($duration -gt 1800) {
        throw 'Simulation would exceed 30 minutes.'
    }
    $step = $metersPerSecond * $IntervalSeconds
    $intervals = [int][Math]::Ceiling($total / $step)
    $count = $intervals + 1
    if ($count -gt 900) {
        throw 'Simulation would exceed 900 GPS samples.'
    }
    $samples = New-Object 'System.Collections.Generic.List[object]'
    $segment = 0
    $distanceBeforeSegment = 0.0
    for ($index = 0; $index -lt $count; $index++) {
        # Evenly distribute the route over the intervals. This avoids a
        # subsecond final ADB update for a tiny leftover piece of road.
        $distance = $total * $index / $intervals
        if ($index -eq $count - 1) { $distance = $total }
        while ($segment -lt $lengths.Count - 1 -and
            $distance -gt $distanceBeforeSegment + $lengths[$segment]) {
            $distanceBeforeSegment += $lengths[$segment]
            $segment++
        }
        $segmentLength = $lengths[$segment]
        if ($segmentLength -le 0) {
            $ratio = 0.0
        } else {
            $ratio = ($distance - $distanceBeforeSegment) / $segmentLength
        }
        $ratio = [Math]::Max(0.0, [Math]::Min(1.0, $ratio))
        $from = $Coordinates[$segment]
        $to = $Coordinates[$segment + 1]
        $lonDelta = $to.Longitude - $from.Longitude
        if ($lonDelta -gt 180) { $lonDelta -= 360 }
        if ($lonDelta -lt -180) { $lonDelta += 360 }
        $lon = $from.Longitude + $lonDelta * $ratio
        if ($lon -gt 180) { $lon -= 360 }
        if ($lon -lt -180) { $lon += 360 }
        $lat = $from.Latitude + ($to.Latitude - $from.Latitude) * $ratio
        $sample = [pscustomobject]@{
            Latitude = $lat
            Longitude = $lon
            DistanceMeters = $distance
            ElapsedSeconds = $distance / $metersPerSecond
        }
        if ($samples.Count -eq 0 -or
            (Format-DemoDecimal $lat) -cne (Format-DemoDecimal $samples[$samples.Count - 1].Latitude) -or
            (Format-DemoDecimal $lon) -cne (Format-DemoDecimal $samples[$samples.Count - 1].Longitude)) {
            $samples.Add($sample)
        }
    }
    if ($samples.Count -lt 2) {
        throw 'Route samples collapse to one GPS coordinate at 10-decimal precision.'
    }
    return [pscustomobject]@{
        Samples = $samples.ToArray()
        GeometryDistanceMeters = $total
        SimulatedDurationSeconds = $duration
        SpeedMetersPerSecond = $metersPerSecond
    }
}

function Assert-DemoOsrmBaseUrl {
    param([string]$OsrmBaseUrl)
    $uri = $null
    if (-not [Uri]::TryCreate($OsrmBaseUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or -not $uri.IsLoopback -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'OSRM URL must be an absolute local loopback HTTP(S) URL without credentials, query or fragment.'
    }
    return $uri.AbsoluteUri.TrimEnd('/')
}

function Get-DemoOsrmRoute {
    param([double]$StartLatitude, [double]$StartLongitude,
          [double]$DestinationLatitude, [double]$DestinationLongitude,
          [string]$OsrmBaseUrl, [scriptblock]$HttpGet)
    $base = Assert-DemoOsrmBaseUrl $OsrmBaseUrl
    $start = (Format-DemoDecimal $StartLongitude) + ',' + (Format-DemoDecimal $StartLatitude)
    $end = (Format-DemoDecimal $DestinationLongitude) + ',' + (Format-DemoDecimal $DestinationLatitude)
    $url = "$base/route/v1/driving/$start;$end`?overview=full&geometries=geojson&steps=false&alternatives=false"
    if ($null -eq $HttpGet) {
        $HttpGet = {
            param($requestUrl)
            $response = Invoke-WebRequest -Uri $requestUrl -Method Get -UseBasicParsing `
                -TimeoutSec 10 -MaximumRedirection 0
            if ([int]$response.StatusCode -ne 200) {
                throw "Local OSRM returned HTTP $($response.StatusCode)."
            }
            $body = [string]$response.Content
            if ([Text.Encoding]::UTF8.GetByteCount($body) -gt 1048576) {
                throw 'OSRM response exceeds 1 MiB.'
            }
            return ConvertFrom-Json -InputObject $body
        }
    }
    try { $response = & $HttpGet $url }
    catch { throw "Local OSRM request failed: $($_.Exception.Message)" }
    return ConvertFrom-DemoOsrmRoute $response $StartLatitude $StartLongitude `
        $DestinationLatitude $DestinationLongitude
}

function Invoke-DemoAdb {
    param([string]$DeviceId, [string[]]$Arguments, [scriptblock]$AdbRunner)
    if ($null -eq $AdbRunner) {
        $AdbRunner = {
            param($serial, [string[]]$adbArguments)
            $adb = Get-Command adb -CommandType Application -ErrorAction Stop
            $prefix = @()
            if (-not [string]::IsNullOrWhiteSpace($serial)) { $prefix = @('-s', $serial) }
            $output = & $adb.Source @prefix @adbArguments 2>&1
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String).Trim() }
        }
    }
    $result = & $AdbRunner $DeviceId $Arguments
    if ($null -eq $result -or $null -eq $result.ExitCode -or
        [int]$result.ExitCode -ne 0) {
        $detail = if ($null -eq $result) { 'no result' } else { [string]$result.Output }
        throw "ADB failed or disconnected: $detail"
    }
    return [string]$result.Output
}

function Assert-DemoEmulator {
    param([string]$DeviceId, [scriptblock]$AdbRunner)
    if ($DeviceId -cnotmatch '^emulator-[0-9]{4,5}$') {
        throw 'Only an explicit emulator-NNNN Android Emulator serial is allowed.'
    }
    $devices = Invoke-DemoAdb '' @('devices', '-l') $AdbRunner
    $serialPattern = [regex]::Escape($DeviceId)
    $matching = @($devices -split "`r?`n" | Where-Object { $_ -match "^$serialPattern\s+" })
    if ($matching.Count -ne 1 -or $matching[0] -notmatch "^$serialPattern\s+device(\s|$)") {
        throw 'Selected emulator is missing, offline, unauthorized or disconnected.'
    }
    if ((Invoke-DemoAdb $DeviceId @('get-state') $AdbRunner).Trim() -cne 'device' -or
        (Invoke-DemoAdb $DeviceId @('get-serialno') $AdbRunner).Trim() -cne $DeviceId -or
        (Invoke-DemoAdb $DeviceId @('shell', 'getprop', 'ro.kernel.qemu') $AdbRunner).Trim() -cne '1' -or
        (Invoke-DemoAdb $DeviceId @('emu', 'avd', 'name') $AdbRunner) -notmatch '(?m)^OK\s*$') {
        throw 'Selected ADB transport did not prove it is an Android Emulator.'
    }
}

function Invoke-DemoGpsRoute {
    param(
        [string]$DeviceId,
        [Nullable[double]]$StartLatitude,
        [Nullable[double]]$StartLongitude,
        [Nullable[double]]$DestinationLatitude,
        [Nullable[double]]$DestinationLongitude,
        [double]$SpeedKmh = 24,
        [double]$IntervalSeconds = 3,
        [int]$HoldAtDestinationSeconds = 0,
        [string]$OsrmBaseUrl = 'http://127.0.0.1:5000',
        [switch]$DryRun,
        [switch]$IUnderstandThisSimulatesGps,
        [switch]$ConfirmSnappedStart,
        [scriptblock]$AdbRunner,
        [scriptblock]$HttpGet,
        [scriptblock]$Wait
    )
    if ([string]::IsNullOrWhiteSpace($DeviceId) -or
        $DeviceId -cnotmatch '^emulator-[0-9]{4,5}$') {
        throw 'An explicit Android Emulator DeviceId such as emulator-5554 is required.'
    }
    if ($null -eq $StartLatitude -or $null -eq $StartLongitude -or
        $null -eq $DestinationLatitude -or $null -eq $DestinationLongitude) {
        throw 'Start and destination latitude/longitude are all required.'
    }
    Assert-DemoCoordinate ([double]$StartLatitude) ([double]$StartLongitude)
    Assert-DemoCoordinate ([double]$DestinationLatitude) ([double]$DestinationLongitude)
    if ($HoldAtDestinationSeconds -lt 0 -or $HoldAtDestinationSeconds -gt 180) {
        throw 'HoldAtDestinationSeconds must be 0 (off) or 1-180 seconds.'
    }
    if (-not $DryRun -and -not $IUnderstandThisSimulatesGps) {
        throw 'Live simulation requires -IUnderstandThisSimulatesGps explicit opt-in.'
    }
    $route = Get-DemoOsrmRoute ([double]$StartLatitude) ([double]$StartLongitude) `
        ([double]$DestinationLatitude) ([double]$DestinationLongitude) $OsrmBaseUrl $HttpGet
    $sampled = Get-DemoRouteSamples $route.Coordinates $SpeedKmh $IntervalSeconds
    $first = $sampled.Samples[0]
    $last = $sampled.Samples[$sampled.Samples.Count - 1]
    $plan = [pscustomobject]@{
        DeviceId = $DeviceId
        Mode = if ($DryRun) { 'DRY_RUN' } else { 'LIVE_EMULATOR' }
        SampleCount = $sampled.Samples.Count
        EmittedSamples = 0
        HoldAtDestinationSeconds = $HoldAtDestinationSeconds
        HoldEmittedSamples = 0
        SimulatedDurationSeconds = $sampled.SimulatedDurationSeconds
        RoadDistanceMeters = $route.RoadDistanceMeters
        GeometryDistanceMeters = $sampled.GeometryDistanceMeters
        StartSnapMeters = $route.StartSnapMeters
        DestinationSnapMeters = $route.DestinationSnapMeters
        FirstLatitude = $first.Latitude
        FirstLongitude = $first.Longitude
        LastLatitude = $last.Latitude
        LastLongitude = $last.Longitude
    }
    Write-Host "SIMULATED GPS ONLY - $($plan.Mode), device=$DeviceId, speed=$SpeedKmh km/h, interval=$IntervalSeconds s"
    Write-Host ("Requested start: lat={0} lon={1}; destination: lat={2} lon={3}; OSRM={4}" -f `
        (Format-DemoDecimal ([double]$StartLatitude)), (Format-DemoDecimal ([double]$StartLongitude)), `
        (Format-DemoDecimal ([double]$DestinationLatitude)), (Format-DemoDecimal ([double]$DestinationLongitude)), `
        (Assert-DemoOsrmBaseUrl $OsrmBaseUrl))
    Write-Host ("OSRM road={0:N1} m, geometry={1:N1} m, samples={2}, simulated duration={3:N1} s" -f `
        $plan.RoadDistanceMeters, $plan.GeometryDistanceMeters, $plan.SampleCount, $plan.SimulatedDurationSeconds)
    Write-Host "Endpoint hold=$HoldAtDestinationSeconds s (9 s updates, maximum 180 s; ADB writes do not prove Backend GPS freshness)"
    Write-Host ("Road start: lon={0} lat={1} (snap={2:N1} m); road end: lon={3} lat={4} (snap={5:N1} m)" -f `
        (Format-DemoDecimal $plan.FirstLongitude), (Format-DemoDecimal $plan.FirstLatitude), $plan.StartSnapMeters, `
        (Format-DemoDecimal $plan.LastLongitude), (Format-DemoDecimal $plan.LastLatitude), $plan.DestinationSnapMeters)
    if ($route.StartSnapMeters -gt 50) {
        Write-Warning 'Road start is over 50 m from requested start. Preposition emulator GPS to the printed road start before live playback; no straight connector will be invented.'
    }
    if ($DryRun) {
        Write-Host 'DryRun complete: emulator transport was NOT checked; no ADB geo fix was sent.'
        return $plan
    }
    if ($route.StartSnapMeters -gt 50 -and -not $ConfirmSnappedStart) {
        throw 'Live route has a >50 m start snap. Preposition emulator to road start and pass -ConfirmSnappedStart.'
    }
    Assert-DemoEmulator $DeviceId $AdbRunner
    if ($null -eq $Wait) {
        $Wait = {
            param([double]$seconds)
            Start-Sleep -Milliseconds ([int][Math]::Round($seconds * 1000))
        }
    }
    $completed = $false
    try {
        $previousElapsed = 0.0
        for ($i = 0; $i -lt $sampled.Samples.Count; $i++) {
            $sample = $sampled.Samples[$i]
            if ($i -gt 0) {
                & $Wait ([Math]::Max(0.0, $sample.ElapsedSeconds - $previousElapsed))
            }
            $lon = Format-DemoDecimal $sample.Longitude
            $lat = Format-DemoDecimal $sample.Latitude
            $output = Invoke-DemoAdb $DeviceId @('emu', 'geo', 'fix', $lon, $lat) $AdbRunner
            if ($output -notmatch '(?m)^OK\s*$') {
                throw "ADB emulator console did not confirm GPS update: $output"
            }
            $plan.EmittedSamples++
            $previousElapsed = $sample.ElapsedSeconds
            if ($i -eq 0 -or $i -eq $sampled.Samples.Count - 1 -or $i % 5 -eq 0) {
                Write-Host ("GPS {0}/{1}: lon={2} lat={3}, route={4:N0} m" -f `
                    ($i + 1), $sampled.Samples.Count, $lon, $lat, $sample.DistanceMeters)
            }
        }
        $heldSeconds = 0
        while ($heldSeconds -lt $HoldAtDestinationSeconds) {
            $delay = [Math]::Min(9, $HoldAtDestinationSeconds - $heldSeconds)
            & $Wait ([double]$delay)
            $heldSeconds += $delay
            $output = Invoke-DemoAdb $DeviceId @('emu', 'geo', 'fix', `
                (Format-DemoDecimal $last.Longitude), (Format-DemoDecimal $last.Latitude)) $AdbRunner
            if ($output -notmatch '(?m)^OK\s*$') {
                throw "ADB emulator console did not confirm endpoint hold: $output"
            }
            $plan.HoldEmittedSamples++
            Write-Host "Endpoint hold $heldSeconds/$HoldAtDestinationSeconds s: same final coordinate, write $($plan.HoldEmittedSamples)"
        }
        $completed = $true
    } finally {
        if (-not $completed) {
            Write-Warning "Simulation stopped after $($plan.EmittedSamples)/$($plan.SampleCount) route updates and $($plan.HoldEmittedSamples) endpoint writes. Emulator remains at its last fix; no background job was started."
        }
    }
    Write-Host "Simulation complete: $($plan.EmittedSamples) road GPS updates and $($plan.HoldEmittedSamples) endpoint writes sent to verified emulator $DeviceId. Backend GPS freshness is unverified. Trip state and CASH were not changed."
    return $plan
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-DemoGpsRoute @PSBoundParameters
}
