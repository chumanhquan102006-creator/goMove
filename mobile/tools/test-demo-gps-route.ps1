#requires -Version 5.1
# Self-contained M4.5B tests. No Pester, emulator, ADB process or OSRM required.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'demo-gps-route.ps1')

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Near {
    param([double]$Expected, [double]$Actual, [double]$Tolerance, [string]$Message)
    if ([Math]::Abs($Expected - $Actual) -gt $Tolerance) {
        throw "Assertion failed: $Message (expected $Expected, got $Actual)"
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $threw = $false
    try { & $Action | Out-Null }
    catch {
        $threw = $true
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Expected error /$Pattern/, got: $($_.Exception.Message)"
        }
    }
    if (-not $threw) { throw "Expected error /$Pattern/, but call succeeded." }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action | Out-Null
        $script:Passed++
        Write-Host "PASS $Name"
    } catch {
        $script:Failed++
        Write-Host "FAIL $Name - $($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-ValidResponse {
    # An eastward road segment followed by a northward segment. Geometry and
    # waypoints are [longitude, latitude], with no input-to-road snap.
    return ConvertFrom-Json @'
{"code":"Ok","routes":[{"distance":90,"duration":14,"geometry":{"type":"LineString","coordinates":[[105.8526,21.0288],[105.8530,21.0288],[105.8530,21.0292]]}}],"waypoints":[{"distance":0,"location":[105.8526,21.0288]},{"distance":0,"location":[105.8530,21.0292]}]}
'@
}

$script:AdbCalls = New-Object 'System.Collections.Generic.List[object]'
$script:HttpUrls = New-Object 'System.Collections.Generic.List[string]'
$script:WaitCalls = New-Object 'System.Collections.Generic.List[double]'
$script:AdbMode = 'normal'
$script:HttpMode = 'valid'
$script:WaitMode = 'normal'
$script:GeoFixCount = 0

function Reset-Fakes {
    $script:AdbCalls.Clear()
    $script:HttpUrls.Clear()
    $script:WaitCalls.Clear()
    $script:AdbMode = 'normal'
    $script:HttpMode = 'valid'
    $script:WaitMode = 'normal'
    $script:GeoFixCount = 0
}

$script:FakeHttp = {
    param($url)
    $script:HttpUrls.Add([string]$url)
    if ($script:HttpMode -eq 'failure') { throw 'OSRM is offline' }
    $response = New-ValidResponse
    if ($script:HttpMode -eq 'large-start-snap') {
        # About 83 m east of the requested start. Provider and actual snap
        # agree; live playback must still require operator confirmation.
        $response.routes[0].geometry.coordinates[0][0] = 105.8534
        $response.waypoints[0].location[0] = 105.8534
        $response.waypoints[0].distance = 83
    }
    return $response
}

$script:FakeAdb = {
    param($serial, [string[]]$arguments)
    $key = $arguments -join ' '
    $script:AdbCalls.Add([pscustomobject]@{ DeviceId = $serial; Arguments = @($arguments); Key = $key })
    switch -Regex ($key) {
        '^devices -l$' {
            if ($script:AdbMode -eq 'missing') {
                return @{ ExitCode = 0; Output = 'List of devices attached' }
            }
            if ($script:AdbMode -eq 'offline') {
                return @{ ExitCode = 0; Output = "List of devices attached`nemulator-5554 offline transport_id:1" }
            }
            return @{ ExitCode = 0; Output = "List of devices attached`nemulator-5554 device product:sdk_gphone model:demo transport_id:1" }
        }
        '^get-state$' { return @{ ExitCode = 0; Output = 'device' } }
        '^get-serialno$' { return @{ ExitCode = 0; Output = 'emulator-5554' } }
        '^shell getprop ro.kernel.qemu$' {
            if ($script:AdbMode -eq 'physical-spoof') { return @{ ExitCode = 0; Output = '0' } }
            return @{ ExitCode = 0; Output = '1' }
        }
        '^emu avd name$' { return @{ ExitCode = 0; Output = "Demo_AVD`nOK" } }
        '^emu geo fix ' {
            $script:GeoFixCount++
            if ($script:AdbMode -eq 'disconnect' -and $script:GeoFixCount -gt 1) {
                return @{ ExitCode = 1; Output = 'device offline' }
            }
            return @{ ExitCode = 0; Output = 'OK' }
        }
        default { throw "Unexpected fake ADB command: $key" }
    }
}

$script:FakeWait = {
    param([double]$seconds)
    $script:WaitCalls.Add($seconds)
    if ($script:WaitMode -eq 'cancel') { throw 'Simulated Ctrl+C cancellation' }
}

function Invoke-TestRoute {
    param([switch]$DryRun, [switch]$OptIn, [switch]$ConfirmSnap,
          [string]$DeviceId = 'emulator-5554')
    $options = @{
        DeviceId = $DeviceId
        StartLatitude = 21.0288
        StartLongitude = 105.8526
        DestinationLatitude = 21.0292
        DestinationLongitude = 105.8530
        SpeedKmh = 24
        IntervalSeconds = 3
        OsrmBaseUrl = 'http://127.0.0.1:5000'
        AdbRunner = $script:FakeAdb
        HttpGet = $script:FakeHttp
        Wait = $script:FakeWait
        DryRun = [bool]$DryRun
        IUnderstandThisSimulatesGps = [bool]$OptIn
        ConfirmSnappedStart = [bool]$ConfirmSnap
    }
    return Invoke-DemoGpsRoute @options
}

Test-Case 'latitude/longitude bounds and finite values' {
    Assert-DemoCoordinate 21.0288 105.8526
    Assert-Throws { Assert-DemoCoordinate 91 105 } 'Latitude/longitude'
    Assert-Throws { Assert-DemoCoordinate 21 181 } 'Latitude/longitude'
    Assert-Throws { Assert-DemoCoordinate ([double]::NaN) 105 } 'Latitude/longitude'
    Assert-Throws { Assert-DemoCoordinate 21 ([double]::PositiveInfinity) } 'Latitude/longitude'
}

Test-Case 'haversine distance preserves small road movements' {
    $meters = Get-DemoDistanceMeters 21.0288 105.8526 21.0288 105.8530
    Assert-True ($meters -gt 35 -and $meters -lt 45) '41 m road edge must not collapse to zero'
}

Test-Case 'GeoJSON longitude/latitude parsing and two road boundaries' {
    $route = ConvertFrom-DemoOsrmRoute (New-ValidResponse) 21.0288 105.8526 21.0292 105.8530
    Assert-True ($route.Coordinates.Count -eq 3) 'three ordered vertices'
    Assert-Near 105.8526 $route.SnappedStart.Longitude 0.00000001 'start longitude'
    Assert-Near 21.0288 $route.SnappedStart.Latitude 0.00000001 'start latitude'
    Assert-Near 105.8530 $route.SnappedDestination.Longitude 0.00000001 'end longitude'
    Assert-Near 21.0292 $route.SnappedDestination.Latitude 0.00000001 'end latitude'
}

Test-Case 'samples interpolate along both road edges without diagonal shortcut' {
    $route = ConvertFrom-DemoOsrmRoute (New-ValidResponse) 21.0288 105.8526 21.0292 105.8530
    $sampled = Get-DemoRouteSamples $route.Coordinates 24 3
    Assert-True ($sampled.Samples.Count -gt 4) 'intermediate samples exist'
    Assert-Near 105.8526 $sampled.Samples[0].Longitude 0.00000001 'first point'
    Assert-Near 21.0292 $sampled.Samples[$sampled.Samples.Count - 1].Latitude 0.00000001 'last point'
    $eastInterior = 0
    $northInterior = 0
    $previous = -1.0
    foreach ($sample in $sampled.Samples) {
        Assert-True ($sample.DistanceMeters -ge $previous) 'distance must be ordered'
        $previous = $sample.DistanceMeters
        $onEast = [Math]::Abs($sample.Latitude - 21.0288) -lt 0.00000001
        $onNorth = [Math]::Abs($sample.Longitude - 105.8530) -lt 0.00000001
        Assert-True ($onEast -or $onNorth) 'sample must remain on one road edge'
        if ($onEast -and $sample.Longitude -gt 105.8526 -and $sample.Longitude -lt 105.8530) { $eastInterior++ }
        if ($onNorth -and $sample.Latitude -gt 21.0288 -and $sample.Latitude -lt 21.0292) { $northInterior++ }
    }
    Assert-True ($eastInterior -gt 0 -and $northInterior -gt 0) 'both edges must contain interpolated positions'
}

Test-Case 'invalid speed, interval, zero-length and tiny routes fail safely' {
    $route = ConvertFrom-DemoOsrmRoute (New-ValidResponse) 21.0288 105.8526 21.0292 105.8530
    Assert-Throws { Get-DemoRouteSamples $route.Coordinates 4 3 } 'speed'
    Assert-Throws { Get-DemoRouteSamples $route.Coordinates 24 1 } 'interval'
    $same = @([pscustomobject]@{ Latitude = 21; Longitude = 105 },
              [pscustomobject]@{ Latitude = 21; Longitude = 105 })
    Assert-Throws { Get-DemoRouteSamples $same 24 3 } 'Zero-length'
    $tiny = @([pscustomobject]@{ Latitude = 21; Longitude = 105 },
              [pscustomobject]@{ Latitude = 21; Longitude = 105.00000000001 })
    Assert-Throws { Get-DemoRouteSamples $tiny 24 3 } 'short|precision|movement'
    $twoMeters = @([pscustomobject]@{ Latitude = 21; Longitude = 105 },
                   [pscustomobject]@{ Latitude = 21; Longitude = 105.00002 })
    Assert-Throws { Get-DemoRouteSamples $twoMeters 24 3 } 'short|duration|interval'
}

Test-Case 'invalid OSRM response and false reported snap are rejected' {
    $response = New-ValidResponse
    $response.code = 'NoRoute'
    Assert-Throws { ConvertFrom-DemoOsrmRoute $response 21.0288 105.8526 21.0292 105.8530 } 'usable route'
    $response = New-ValidResponse
    $response.routes[0].geometry.type = 'Point'
    Assert-Throws { ConvertFrom-DemoOsrmRoute $response 21.0288 105.8526 21.0292 105.8530 } 'LineString'
    $response = New-ValidResponse
    $response.routes[0].geometry.coordinates[0] = @(21.0288, 105.8526)
    Assert-Throws { ConvertFrom-DemoOsrmRoute $response 21.0288 105.8526 21.0292 105.8530 } 'coordinate|Latitude/longitude'
    $response = New-ValidResponse
    $response.routes[0].geometry.coordinates[0][0] = 105.8556
    $response.waypoints[0].location[0] = 105.8556
    $response.waypoints[0].distance = 10
    Assert-Throws { ConvertFrom-DemoOsrmRoute $response 21.0288 105.8526 21.0292 105.8530 } 'too far'
}

Test-Case 'local OSRM URL cannot target remote service or contain credentials' {
    Assert-True ((Assert-DemoOsrmBaseUrl 'http://127.0.0.1:5000') -eq 'http://127.0.0.1:5000') 'loopback accepted'
    Assert-Throws { Assert-DemoOsrmBaseUrl 'http://example.com:5000' } 'local loopback'
    Assert-Throws { Assert-DemoOsrmBaseUrl 'http://user:secret@localhost:5000' } 'local loopback'
    Assert-Throws { Assert-DemoOsrmBaseUrl 'http://127.0.0.1:5000/?x=1' } 'local loopback'
}

Test-Case 'DryRun validates route and never touches ADB or waits' {
    Reset-Fakes
    $plan = Invoke-TestRoute -DryRun 6>$null
    Assert-True ($plan.Mode -eq 'DRY_RUN' -and $plan.SampleCount -gt 2) 'DryRun plan'
    Assert-True ($plan.EmittedSamples -eq 0) 'no GPS emission'
    Assert-True ($script:AdbCalls.Count -eq 0 -and $script:WaitCalls.Count -eq 0) 'no ADB or wait'
    Assert-True ($script:HttpUrls.Count -eq 1) 'one OSRM request'
    Assert-True ($script:HttpUrls[0].Contains('/105.8526000000,21.0288000000;105.8530000000,21.0292000000?')) 'OSRM URL longitude first'
}

Test-Case 'live run requires opt-in before any OSRM or ADB call' {
    Reset-Fakes
    Assert-Throws { Invoke-TestRoute } 'explicit opt-in'
    Assert-True ($script:HttpUrls.Count -eq 0 -and $script:AdbCalls.Count -eq 0) 'no side effects'
}

Test-Case 'physical serial, absent emulator and offline emulator are rejected' {
    Reset-Fakes
    Assert-Throws { Invoke-TestRoute -OptIn -DeviceId 'R58M123ABC' } 'DeviceId|Emulator'
    Assert-True ($script:HttpUrls.Count -eq 0) 'physical serial rejected before OSRM'
    $script:AdbMode = 'missing'
    Assert-Throws { Invoke-TestRoute -OptIn 6>$null } 'missing|offline|disconnected'
    Assert-True ($script:GeoFixCount -eq 0) 'missing emulator never receives geo fix'
    Reset-Fakes
    $script:AdbMode = 'offline'
    Assert-Throws { Invoke-TestRoute -OptIn 6>$null } 'missing|offline|disconnected'
    Assert-True ($script:GeoFixCount -eq 0) 'offline emulator never receives geo fix'
}

Test-Case 'spoofed emulator serial with physical transport is rejected' {
    Reset-Fakes
    $script:AdbMode = 'physical-spoof'
    Assert-Throws { Invoke-TestRoute -OptIn 6>$null } 'did not prove'
    Assert-True ($script:GeoFixCount -eq 0) 'no geo fix to physical transport'
}

Test-Case 'large start snap requires separate confirmation before ADB' {
    Reset-Fakes
    $script:HttpMode = 'large-start-snap'
    Assert-Throws { Invoke-TestRoute -OptIn 6>$null } 'ConfirmSnappedStart'
    Assert-True ($script:AdbCalls.Count -eq 0) 'no ADB before snap confirmation'
    $plan = Invoke-TestRoute -OptIn -ConfirmSnap 6>$null 3>$null
    Assert-True ($plan.StartSnapMeters -gt 50 -and $plan.EmittedSamples -gt 0) 'confirmed snapped route emitted'
}

Test-Case 'live ADB geo fix uses longitude then latitude and stays on one serial' {
    Reset-Fakes
    $plan = Invoke-TestRoute -OptIn 6>$null
    $geos = @($script:AdbCalls | Where-Object { $_.Key -like 'emu geo fix *' })
    Assert-True ($geos.Count -eq $plan.SampleCount) 'one ADB fix per sample'
    Assert-True ($geos[0].DeviceId -ceq 'emulator-5554') 'explicit emulator serial'
    Assert-True ($geos[0].Arguments[3] -ceq '105.8526000000') 'first ADB coordinate is longitude'
    Assert-True ($geos[0].Arguments[4] -ceq '21.0288000000') 'second ADB coordinate is latitude'
    Assert-True ($geos[$geos.Count - 1].Arguments[3] -ceq '105.8530000000') 'last longitude is destination'
    Assert-True ($geos[$geos.Count - 1].Arguments[4] -ceq '21.0292000000') 'last latitude is destination'
    Assert-True ($script:WaitCalls.Count -eq $plan.SampleCount - 1) 'wait only between samples'
    $waitTotal = 0.0
    foreach ($delay in $script:WaitCalls) {
        Assert-True ($delay -gt 2 -and $delay -le 3) 'distributed waits stay positive and near configured interval'
        $waitTotal += $delay
    }
    Assert-Near $plan.SimulatedDurationSeconds $waitTotal 0.01 'waits total simulated duration'
}

Test-Case 'OSRM failure stops before any GPS mutation' {
    Reset-Fakes
    $script:HttpMode = 'failure'
    Assert-Throws { Invoke-TestRoute -OptIn 6>$null } 'OSRM request failed'
    Assert-True ($script:AdbCalls.Count -eq 0) 'no ADB after routing failure'
}

Test-Case 'ADB disconnect and Ctrl+C-like wait stop without background jobs' {
    Reset-Fakes
    $jobsBefore = @(Get-Job -ErrorAction SilentlyContinue).Count
    $script:AdbMode = 'disconnect'
    Assert-Throws { Invoke-TestRoute -OptIn 6>$null 3>$null } 'ADB failed|disconnected'
    Assert-True ($script:GeoFixCount -eq 2) 'stopped on first disconnected fix'
    Reset-Fakes
    $script:WaitMode = 'cancel'
    Assert-Throws { Invoke-TestRoute -OptIn 6>$null 3>$null } 'Simulated Ctrl\+C'
    Assert-True ($script:GeoFixCount -eq 1) 'no further fix after cancellation'
    Assert-True (@(Get-Job -ErrorAction SilentlyContinue).Count -eq $jobsBefore) 'no background job leaked'
}

Test-Case 'repeated live execution is independent and leaves no jobs' {
    Reset-Fakes
    $jobsBefore = @(Get-Job -ErrorAction SilentlyContinue).Count
    $first = Invoke-TestRoute -OptIn 6>$null
    $firstCount = $script:GeoFixCount
    $second = Invoke-TestRoute -OptIn 6>$null
    Assert-True ($first.EmittedSamples -eq $firstCount) 'first run complete'
    Assert-True ($second.EmittedSamples -eq $firstCount) 'second run complete'
    Assert-True ($script:GeoFixCount -eq 2 * $firstCount) 'second run does not inherit sample index'
    Assert-True (@(Get-Job -ErrorAction SilentlyContinue).Count -eq $jobsBefore) 'no background job leaked'
}

Write-Host "Simulator tests: $script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) { exit 1 }
