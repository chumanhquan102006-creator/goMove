#requires -Version 5.1
# Fully mocked: no Docker, ADB, network, device, or Git commands are run.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'check-demo-readiness.ps1')
$script:passed = 0
$script:failed = 0
$script:values = @{}
$script:calls = New-Object 'System.Collections.Generic.List[string]'
$script:probe = {
    param($name)
    $script:calls.Add($name)
    return $script:values[$name]
}

function Reset-Values {
    $script:calls.Clear()
    $script:values = @{
        paths = $true; branch = 'feature/mobile-demo-readiness'; dirty = $false
        docker = $true; postgres = 'healthy'; osrm = $true; backend = $true
        adb = $true
        devices = (@('List of devices attached', 'emulator-5554 device product:demo',
            'R58NOKIA device product:nokia') -join [Environment]::NewLine)
        wifi = '192.168.1.22'; flutter = $true; java = $true
    }
}
function Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Case {
    param([string]$Name, [scriptblock]$Body)
    try { Reset-Values; & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host ("FAIL {0}: {1}" -f $Name, $_.Exception.Message) }
}
function Run-Check {
    return Invoke-DemoReadiness -Probe $script:probe 6>$null
}
function Status-Of {
    param($Result, [string]$Name)
    return @($Result.Results | Where-Object { $_.Check -eq $Name })[0].Status
}

Case 'all services available returns exit zero' {
    $result = Run-Check
    Check ($result.ExitCode -eq 0) 'exit code'
    Check (@($result.Results | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0) 'no blocking failures'
    Check ((Status-Of $result 'PostgreSQL') -eq 'PASS') 'healthy DB'
    Check ((Status-Of $result 'Customer device') -eq 'PASS') 'connected Nokia'
}
Case 'HTTP JSON response decodes byte arrays and strings' {
    $bytes = [Text.Encoding]::UTF8.GetBytes('{"status":"UP"}')
    Check ((ConvertFrom-ReadinessResponseJson $bytes).status -eq 'UP') 'byte array health JSON'
    Check ((ConvertFrom-ReadinessResponseJson '{"code":"Ok"}').code -eq 'Ok') 'string OSRM JSON'
}
Case 'Docker unavailable skips PostgreSQL and fails' {
    $script:values.docker = $false
    $result = Run-Check
    Check ($result.ExitCode -eq 1) 'blocking Docker'
    Check ((Status-Of $result 'PostgreSQL') -eq 'SKIP') 'dependent DB skipped'
    Check (-not $script:calls.Contains('postgres')) 'no Docker inspect probe'
}
Case 'PostgreSQL unhealthy fails' {
    $script:values.postgres = 'unhealthy'
    Check ((Status-Of (Run-Check) 'PostgreSQL') -eq 'FAIL') 'DB failure'
}
Case 'Backend unavailable fails independently' {
    $script:values.backend = $false
    Check ((Status-Of (Run-Check) 'Spring health') -eq 'FAIL') 'backend failure'
}
Case 'OSRM unavailable fails independently' {
    $script:values.osrm = $false
    Check ((Status-Of (Run-Check) 'Local OSRM') -eq 'FAIL') 'OSRM failure'
}
Case 'missing ADB skips device checks' {
    $script:values.adb = $false
    $result = Run-Check
    Check ((Status-Of $result 'ADB CLI') -eq 'FAIL') 'ADB failure'
    Check ((Status-Of $result 'Driver emulator') -eq 'SKIP') 'emulator skipped'
    Check (-not $script:calls.Contains('devices')) 'no adb devices probe'
}
Case 'no emulator fails, physical Customer remains optional' {
    $script:values.devices = (@('List of devices attached', 'R58NOKIA device product:nokia') -join [Environment]::NewLine)
    $result = Run-Check
    Check ((Status-Of $result 'Driver emulator') -eq 'FAIL') 'emulator required'
    Check ((Status-Of $result 'Customer device') -eq 'PASS') 'physical detected'
    $script:values.devices = (@('List of devices attached', 'emulator-5554 device product:demo') -join [Environment]::NewLine)
    Check ((Status-Of (Run-Check) 'Customer device') -eq 'WARN') 'physical optional'
}
Case 'offline transports are not counted as connected' {
    $script:values.devices = (@('List of devices attached', 'emulator-5554 offline', 'R58NOKIA offline') -join [Environment]::NewLine)
    $result = Run-Check
    Check ((Status-Of $result 'Driver emulator') -eq 'FAIL') 'offline emulator rejected'
    Check ((Status-Of $result 'Customer device') -eq 'WARN') 'offline Nokia warning'
}
Case 'malformed Wi-Fi address is only a warning' {
    $script:values.wifi = '999.999.1.1'
    $result = Run-Check
    Check ($result.ExitCode -eq 0) 'optional Wi-Fi'
    Check ((Status-Of $result 'Wi-Fi IPv4') -eq 'WARN') 'invalid IP warning'
}
Case 'invalid local URL rejects without probing or echoing credentials' {
    $message = ''
    try {
        Invoke-DemoReadiness -Probe $script:probe -BackendUrl 'http://user:supersecret@localhost:8080' 6>$null | Out-Null
    } catch { $message = $_.Exception.Message }
    Check ($message -match 'loopback') 'invalid URL rejected'
    Check ($message -notmatch 'supersecret') 'credential not echoed'
    Check ($script:calls.Count -eq 0) 'no probe ran'
}
Case 'summary omits raw device details and credentials' {
    $script:values.devices = (@('List of devices attached', 'emulator-5554 device token=never-print-this') -join [Environment]::NewLine)
    $output = (Invoke-DemoReadiness -Probe $script:probe 6>&1 | Out-String)
    Check ($output -notmatch 'never-print-this') 'raw ADB details not printed'
    Check ($output -match 'Summary:') 'summary printed'
}
Case 'checker uses only injected read-only probes' {
    $result = Run-Check
    Check ($result.ExitCode -eq 0) 'mock result'
    $expected = @('paths','branch','dirty','docker','postgres','osrm','backend','adb','devices','wifi','flutter','java')
    Check (($script:calls -join ',') -eq ($expected -join ',')) 'only expected read probes'
}
Case 'default probe resolves Get-ReadinessProbe without injection' {
    # This exercises the production branch that constructs $Probe internally.
    # A local function shadows the real probes so no services are required.
    function Get-ReadinessProbe {
        param($Name, $Root, $BackendUrl, $OsrmUrl)
        Check ($Root -like '*goMove' -and $BackendUrl -eq 'http://127.0.0.1:8080' -and
            $OsrmUrl -eq 'http://127.0.0.1:5000') 'default probe receives local values'
        $script:calls.Add($Name)
        return $script:values[$Name]
    }
    $result = Invoke-DemoReadiness 6>$null
    Check ($result.ExitCode -eq 0) 'default path completes'
    Check ((Status-Of $result 'Spring health') -eq 'PASS') 'default path reads probe results'
    Check ($script:calls.Contains('paths') -and $script:calls.Contains('java')) 'default function called throughout'
}

Write-Host "Readiness tests: $script:passed passed, $script:failed failed."
if ($script:failed -gt 0) { exit 1 }
