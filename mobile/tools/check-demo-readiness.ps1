#requires -Version 5.1
# Read-only local demo checks. Dot-source to inject probes in tests.
[CmdletBinding()]
param(
    [string]$ExpectedBranch = 'feature/mobile-demo-readiness',
    [string]$BackendUrl = 'http://127.0.0.1:8080',
    [string]$OsrmUrl = 'http://127.0.0.1:5000'
)

function Assert-ReadinessLocalUrl {
    param([string]$Value)
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or -not $uri.IsLoopback -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'Readiness service URLs must be local loopback HTTP(S) origins without credentials.'
    }
    return $uri.AbsoluteUri.TrimEnd('/')
}

function ConvertFrom-ReadinessResponseJson {
    param($Content)
    $body = if ($Content -is [byte[]]) {
        [Text.Encoding]::UTF8.GetString($Content)
    } else { [string]$Content }
    return ConvertFrom-Json -InputObject $body
}

function Get-ReadinessProbe {
    param([string]$Name, [string]$Root, [string]$BackendUrl, [string]$OsrmUrl)
    switch ($Name) {
        'paths' {
            return (Test-Path (Join-Path $Root 'backend')) -and
                (Test-Path (Join-Path $Root 'mobile')) -and
                (Test-Path (Join-Path $Root 'docker-compose.yml')) -and
                (Test-Path (Join-Path $Root '.git'))
        }
        'branch' {
            if ($null -eq (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { return '' }
            return (& git -C $Root branch --show-current 2>$null | Out-String).Trim()
        }
        'dirty' {
            if ($null -eq (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { return $false }
            return ((& git -C $Root status --porcelain 2>$null | Out-String).Trim().Length -gt 0)
        }
        'docker' { return $null -ne (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue) }
        'postgres' {
            try {
                $raw = & docker inspect --format '{{json .State}}' gomove-postgres 2>$null
                if ($LASTEXITCODE -ne 0) { return 'missing' }
                $state = $raw | ConvertFrom-Json
                if ($state.Running -and $state.Health.Status -eq 'healthy') { return 'healthy' }
                return 'unhealthy'
            } catch { return 'missing' }
        }
        'osrm' {
            try {
                $url = "$OsrmUrl/route/v1/driving/105.8526,21.0288;105.8440,21.0298?overview=false"
                $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 4 -MaximumRedirection 0
                return ($response.StatusCode -eq 200 -and
                    (ConvertFrom-ReadinessResponseJson $response.Content).code -eq 'Ok')
            } catch { return $false }
        }
        'backend' {
            try {
                $response = Invoke-WebRequest -Uri "$BackendUrl/actuator/health" -UseBasicParsing -TimeoutSec 4 -MaximumRedirection 0
                return ($response.StatusCode -eq 200 -and
                    (ConvertFrom-ReadinessResponseJson $response.Content).status -eq 'UP')
            } catch { return $false }
        }
        'adb' { return $null -ne (Get-Command adb -CommandType Application -ErrorAction SilentlyContinue) }
        'devices' {
            try {
                $output = & adb devices -l 2>$null
                if ($LASTEXITCODE -ne 0) { return '' }
                return ($output | Out-String)
            } catch { return '' }
        }
        'wifi' {
            try {
                $address = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                    Where-Object { $_.InterfaceAlias -match 'Wi-?Fi|WLAN|Wireless' -and
                        $_.IPAddress -notmatch '^(169\.254\.|127\.)' } |
                    Select-Object -First 1 -ExpandProperty IPAddress
                return [string]$address
            } catch { return '' }
        }
        'flutter' { return $null -ne (Get-Command flutter -CommandType Application -ErrorAction SilentlyContinue) }
        'java' { return $null -ne (Get-Command java -CommandType Application -ErrorAction SilentlyContinue) }
    }
    throw "Unknown readiness probe: $Name"
}

function Add-ReadinessCheck {
    param($Results, [string]$Name, [string]$Status, [string]$Detail)
    $Results.Add([pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail })
}

function Invoke-DemoReadiness {
    param(
        [string]$ExpectedBranch = 'feature/mobile-demo-readiness',
        [string]$BackendUrl = 'http://127.0.0.1:8080',
        [string]$OsrmUrl = 'http://127.0.0.1:5000',
        [scriptblock]$Probe
    )
    $backend = Assert-ReadinessLocalUrl $BackendUrl
    $osrm = Assert-ReadinessLocalUrl $OsrmUrl
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    if ($null -eq $Probe) {
        $Probe = { param($name) Get-ReadinessProbe $name $root $backend $osrm }
    }
    $results = New-Object 'System.Collections.Generic.List[object]'
    if (& $Probe 'paths') {
        Add-ReadinessCheck $results 'Repository paths' 'PASS' 'backend, mobile, Compose and Git found'
    } else { Add-ReadinessCheck $results 'Repository paths' 'FAIL' 'expected GoMove paths missing' }
    $branch = [string](& $Probe 'branch')
    if ($branch -ceq $ExpectedBranch) {
        Add-ReadinessCheck $results 'Git branch' 'PASS' $branch
    } else { Add-ReadinessCheck $results 'Git branch' 'WARN' "current=$branch; expected=$ExpectedBranch" }
    if (& $Probe 'dirty') {
        Add-ReadinessCheck $results 'Git worktree' 'WARN' 'uncommitted changes present'
    } else { Add-ReadinessCheck $results 'Git worktree' 'PASS' 'clean' }
    if (& $Probe 'docker') {
        Add-ReadinessCheck $results 'Docker CLI' 'PASS' 'available'
        if ((& $Probe 'postgres') -eq 'healthy') {
            Add-ReadinessCheck $results 'PostgreSQL' 'PASS' 'gomove-postgres running and healthy'
        } else { Add-ReadinessCheck $results 'PostgreSQL' 'FAIL' 'gomove-postgres missing or unhealthy' }
    } else {
        Add-ReadinessCheck $results 'Docker CLI' 'FAIL' 'unavailable'
        Add-ReadinessCheck $results 'PostgreSQL' 'SKIP' 'Docker CLI unavailable'
    }
    if (& $Probe 'osrm') {
        Add-ReadinessCheck $results 'Local OSRM' 'PASS' 'Hanoi route responds Ok'
    } else { Add-ReadinessCheck $results 'Local OSRM' 'FAIL' 'Hanoi route unavailable' }
    if (& $Probe 'backend') {
        Add-ReadinessCheck $results 'Spring health' 'PASS' '/actuator/health reports UP'
    } else { Add-ReadinessCheck $results 'Spring health' 'FAIL' '/actuator/health unavailable or not UP' }
    if (& $Probe 'adb') {
        Add-ReadinessCheck $results 'ADB CLI' 'PASS' 'available'
        $devices = [string](& $Probe 'devices')
        $online = @($devices -split "`r?`n" | Where-Object { $_ -match '^\S+\s+device(\s|$)' })
        $emulator = @($online | Where-Object { $_ -match '^emulator-[0-9]{4,5}\s+' })
        $physical = @($online | Where-Object { $_ -notmatch '^emulator-[0-9]{4,5}\s+' })
        if ($emulator.Count -gt 0) {
            Add-ReadinessCheck $results 'Driver emulator' 'PASS' "$($emulator.Count) connected"
        } else { Add-ReadinessCheck $results 'Driver emulator' 'FAIL' 'no online Android Emulator' }
        if ($physical.Count -gt 0) {
            Add-ReadinessCheck $results 'Customer device' 'PASS' "$($physical.Count) physical device(s) connected"
        } else { Add-ReadinessCheck $results 'Customer device' 'WARN' 'optional physical device absent or offline' }
    } else {
        Add-ReadinessCheck $results 'ADB CLI' 'FAIL' 'unavailable'
        Add-ReadinessCheck $results 'Driver emulator' 'SKIP' 'ADB CLI unavailable'
        Add-ReadinessCheck $results 'Customer device' 'SKIP' 'ADB CLI unavailable'
    }
    $ip = [string](& $Probe 'wifi')
    $address = $null
    if ([System.Net.IPAddress]::TryParse($ip, [ref]$address) -and
        $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
        -not [System.Net.IPAddress]::IsLoopback($address) -and
        -not $ip.StartsWith('169.254.')) {
        Add-ReadinessCheck $results 'Wi-Fi IPv4' 'PASS' $ip
    } else { Add-ReadinessCheck $results 'Wi-Fi IPv4' 'WARN' 'unavailable; inspect active Wi-Fi adapter' }
    foreach ($name in @('flutter', 'java')) {
        if (& $Probe $name) { Add-ReadinessCheck $results $name.ToUpperInvariant() 'PASS' 'available' }
        else { Add-ReadinessCheck $results $name.ToUpperInvariant() 'WARN' 'optional CLI unavailable' }
    }
    foreach ($item in $results) { Write-Host ("[{0}] {1}: {2}" -f $item.Status, $item.Check, $item.Detail) }
    $failures = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $warnings = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
    $exitCode = if ($failures -gt 0) { 1 } else { 0 }
    Write-Host "Summary: $failures blocking FAIL, $warnings WARN; exit code $exitCode. Read-only checks complete."
    return [pscustomobject]@{ Results = $results.ToArray(); ExitCode = $exitCode }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-DemoReadiness @PSBoundParameters
        exit $result.ExitCode
    } catch {
        Write-Host "[FAIL] Readiness configuration: $($_.Exception.Message)"
        exit 1
    }
}
