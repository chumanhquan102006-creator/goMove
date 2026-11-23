#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('StaticPreflight','Init','Restore','Validate','FlutterTests','BackendTests','BuildJar','BuildImage','VerifyImage','Deploy','Smoke')][string]$Action)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$RepositoryUrl='https://github.com/chumanhquan102006-creator/goMove.git'
$script:DemoState=$null

function FullPath([string]$Path) { [IO.Path]::GetFullPath($Path).TrimEnd('\','/') }

function IsWithin([string]$Path, [string]$Parent) {
    (FullPath $Path).StartsWith((FullPath $Parent) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function HashBytes([byte[]]$Bytes) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }

function HashFile([string]$Path) { HashBytes ([IO.File]::ReadAllBytes($Path)) }

function SafeLine([string]$Line) {
    $Line = $Line -replace '\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b','[TOKEN]'
    $Line = $Line -replace '\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}','[PASSWORD_HASH]'
    $Line -replace '(?i)(Bearer\s+)\S+','$1[REDACTED]'
}

function SafeGitLine([string]$Line) {
    $Line = SafeLine $Line
    $Line = $Line -replace '(?i)([a-z][a-z0-9+.-]*://)[^/\s@]+@','$1[REDACTED]@'
    $Line = $Line -replace '(?i)\b(?:proxy-)?authorization\s*:\s*[^\r\n]+','Authorization: [REDACTED]'
    $Line = $Line -replace '(?i)\b(password|passwd|pwd|token|secret|authorization|credential)\s*[:=]\s*(?:"[^"]*"|''[^'']*''|[^\s]+)','$1=[REDACTED]'
    $Line = $Line -replace '(?i)[A-Z]:[\\/]Users[\\/][^\\/\r\n]+','[USERPROFILE]'
    if ($Line.Length -gt 2000) { $Line = $Line.Substring(0,2000) + ' [TRUNCATED]' }
    $Line
}

function Native([string]$File, [string[]]$Arguments, [string]$InputText, [switch]$Show,
    [ValidateSet('CheckoutCommit','CheckoutTree')][string]$GitOperation) {
    $gitCommand = $null
    if ($GitOperation) {
        if ($File -ne 'git' -or $PSBoundParameters.ContainsKey('InputText')) { throw 'Git diagnostics require a read-only Checkout Git probe' }
        $expected = if ($GitOperation -eq 'CheckoutCommit') { @('-C',$SourceRepository,'rev-parse',($Revision + '^{commit}')) }
            else { @('-C',$SourceRepository,'diff','--quiet',$Revision,'--','backend','mobile') }
        if ($Arguments.Count -ne $expected.Count) { throw 'Unexpected Checkout diagnostic arguments' }
        for ($i = 0; $i -lt $expected.Count; $i++) {
            if ($Arguments[$i] -cne $expected[$i]) { throw 'Unexpected Checkout diagnostic arguments' }
        }
        $gitCommand = Get-Command $File -ErrorAction Stop
    }
    # Ignore inherited indexed overrides for Git and Flutter's Git subprocesses.
    # Restore the caller's environment after the synchronous invocation.
    $isolateGitOverrides = $File -in @('git','flutter')
    $priorGitConfigCount = if ($isolateGitOverrides) { [Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT','Process') } else { $null }
    try {
        if ($isolateGitOverrides) { [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT','0','Process') }
        if ($PSBoundParameters.ContainsKey('InputText')) { $out = @($InputText | & $File @Arguments 2>&1) }
        else { $out = @(& $File @Arguments 2>&1) }
        $code = $LASTEXITCODE
    } finally {
        if ($isolateGitOverrides) { [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT',$priorGitConfigCount,'Process') }
    }
    $text = ($out | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($GitOperation) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $diagnostic = [ordered]@{
            operation = $GitOperation; exitCode = $code
            commandType = $gitCommand.CommandType.ToString()
            executable = if ($gitCommand.CommandType -eq 'Application') { SafeGitLine $gitCommand.Source } else { '[NON-APPLICATION COMMAND]' }
            arguments = @($Arguments | ForEach-Object { SafeGitLine $_ })
            workingDirectory = SafeGitLine (Get-Location).ProviderPath
            processDirectory = SafeGitLine ([Environment]::CurrentDirectory)
            identitySid = $identity.User.Value
            isAdministrator = [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            powerShellVersion = $PSVersionTable.PSVersion.ToString()
            argumentPassing = [string]$PSNativeCommandArgumentPassing
            stdoutAndStderr = @($out | Select-Object -First 20 | ForEach-Object { SafeGitLine $_.ToString() })
            outputTruncated = $out.Count -gt 20
        }
        Write-Host ('Phase5 Git diagnostic: ' + ($diagnostic | ConvertTo-Json -Depth 4 -Compress))
    }
    if ($Show) { $out | ForEach-Object { Write-Host (SafeLine $_.ToString()) } }
    if ($code -ne 0) {
        $operationSuffix = if ($GitOperation) { " operation=$GitOperation" } else { '' }
        throw "Native command $File failed with exitCode=$code$operationSuffix"
    }
    $text.Trim()
}

function ResourceGate {
    $os = Get-CimInstance Win32_OperatingSystem
    $bytes = [int64]$os.FreePhysicalMemory * 1024
    $r = @{ time = [DateTimeOffset]::Now.ToString('o'); availableBytes = $bytes; requiredBytes = 6GB }
    if ($null -ne $script:DemoState) { Record ('resource-' + $Action) $r }
    if ($bytes -lt 6GB) { throw ('RESOURCE_GATE: available {0:F3} GiB below 6 GiB' -f ($bytes / 1GB)) }
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem | Where-Object Name -in @('C','D'))) {
        if ($drive.Free -lt 5GB) { throw 'RESOURCE_GATE: less than 5 GiB disk headroom' }
    }
    $docker = Native docker @('info','--format','{{.OSType}}|{{.MemTotal}}|{{.NCPU}}')
    $parts = $docker.Split('|')
    if ($parts[0] -ne 'linux' -or [int64]$parts[1] -lt 4GB) { throw 'Docker Linux resources not ready' }
}

function ProtectedSnapshot {
    $result = @{}
    $names = (Native docker @('ps','-a','--format','{{.Names}}')).Split([char]10) |
        Where-Object { $_ -match '^gomove-platform-|^gomove-phase4d-|^gomove-manual-staging-|^gomove-jenkins-demo-' }
    foreach ($name in $names) {
        $name = $name.Trim()
        $result[$name] = Native docker @('inspect','--format','{{.Id}}|{{.State.StartedAt}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}',$name)
    }
    if ($result.Count -lt 12) { throw 'Protected Platform/sandbox baseline not found' }
    $result
}

function FreePort([int]$Port) {
    $socket = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    try { $socket.Start() } finally { $socket.Stop() }
}

function WaitHealthy([string]$Service) {
    $until = [DateTime]::UtcNow.AddSeconds(150)
    do {
        $m = Container $Service
        if ($m.State.Status -ne 'running' -or $m.State.OOMKilled) { throw "$Service stopped or OOMKilled; preserve evidence" }
        if ($m.State.Health.Status -eq 'healthy') { return $m }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $until)
    throw "$Service health timeout; no repair/retry"
}

function HttpUp([string]$Path) {
    if ($Path -notin @('/actuator/health','/actuator/health/readiness')) { throw 'Only read-only health smoke is allowed' }
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromSeconds(10)
    try {
        $response = $client.GetAsync('http://127.0.0.1:18094' + $Path).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        if ([int]$response.StatusCode -ne 200 -or $body.status -ne 'UP') { throw 'CI HTTP smoke failed' }
        @{ path = $Path; httpStatus = 200; status = 'UP' }
    } finally { $client.Dispose(); $handler.Dispose() }
}

function Record([string]$Name,$Data) {
    $script:DemoState.steps[$Name]=@{time=[DateTimeOffset]::Now.ToString('o');data=$Data}
    SaveState
    Write-Host ("GoMove demo {0}: recorded" -f $Name)
}
function SaveState {
    if($null -ne $script:DemoState){[IO.File]::WriteAllText($StatePath,($script:DemoState|ConvertTo-Json -Depth 24),[Text.UTF8Encoding]::new($false))}
}
function TrustedPath([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path) -or ![IO.Path]::IsPathFullyQualified($Path) -or $Path -match '["\r\n%!]'){throw 'Invalid absolute Windows path'}
    FullPath $Path
}
function ContextGate {
    $expectedHome=Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData/Local/GoMove/JenkinsPhase5/controller-20261123-df0804b/home'
    if(!$IsWindows -or (TrustedPath $env:JENKINS_HOME) -ne (TrustedPath $expectedHome) -or $env:JOB_NAME -ne 'GoMove-GitHub-Demo-CI'){throw 'Wrong isolated controller/job'}
    if($env:BUILD_NUMBER -notmatch '^[1-9][0-9]{0,8}$' -or $env:DEMO_COMMIT_SHA -notmatch '^[0-9a-fA-F]{40}$'){throw 'Missing actual SCM revision/build number'}
    $script:Source=TrustedPath $env:DEMO_SOURCE
    $workspace=TrustedPath $env:WORKSPACE
    if(!(IsWithin $workspace (Join-Path $expectedHome 'workspace')) -or !(IsWithin $Source $workspace)){throw 'Source is not inside the isolated Jenkins workspace'}
    if($env:DEMO_PUSH_CAUSE_VERIFIED -ne 'true'){throw 'Real GitHub push cause was not verified'}
    if((Native git @('-C',$Source,'rev-parse','HEAD')) -ne $env:DEMO_COMMIT_SHA){throw 'SCM revision mismatch'}
    if((Native git @('-C',$Source,'remote','get-url','origin')) -ne $RepositoryUrl){throw 'Unexpected GitHub remote'}
}
function ConfigHashes {
    $proof=@{}
    foreach($name in @('Jenkinsfile.demo','ci/Invoke-GoMoveDemo.ps1','ci/Dockerfile.demo','compose.demo-staging.yaml')){$proof[$name]=HashFile (Join-Path $Source $name)}
    $proof
}
function SourceGate {
    Native git @('-C',$Source,'diff','--quiet','HEAD','--','backend','mobile','ci','Jenkinsfile.demo','compose.demo-staging.yaml')|Out-Null
    if(Native git @('-C',$Source,'ls-files','--others','--exclude-standard','--','backend/src','mobile/lib','mobile/test')){throw 'Unexpected untracked application source'}
}
function Compose([string[]]$Arguments) {
    Native docker (@('compose','--env-file',$EmptyEnv,'-p',$Project,'-f',(Join-Path $Source 'compose.demo-staging.yaml'))+$Arguments)
}
function Container([string]$Service) {
    if($Service -notin @('postgres','osrm','backend')){throw 'Unknown staging service'}
    $id=Compose @('ps','-a','-q',$Service)
    if($id -notmatch '^[0-9a-f]{64}$'){throw 'Missing unique staging container'}
    $metadata=Native docker @('inspect','--format','{{json .}}',$id)|ConvertFrom-Json -AsHashtable
    if($metadata.Config.Labels['com.docker.compose.project'] -ne $Project -or $metadata.Config.Labels['com.docker.compose.service'] -ne $Service){throw 'Container project/service mismatch'}
    $metadata
}
$TcpPsql='PGPASSWORD="$(cat /run/secrets/bootstrap-db-password)" PGCONNECT_TIMEOUT=3 PGOPTIONS="-c statement_timeout=5000" psql -h 127.0.0.1 -p 5432 -w -X -q -A -t -v ON_ERROR_STOP=1 -U gomove_demo_bootstrap -d gomove_demo_ci'
function Sql([string]$Statement,[switch]$Write) {
    $pg=Container 'postgres'
    $begin=if($Write){'BEGIN;'}else{'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;'}
    $guard='DO $$ BEGIN IF current_database() <> ''gomove_demo_ci'' THEN RAISE EXCEPTION ''Wrong demo CI DB''; END IF; END $$;'
    Native docker @('exec','-i','--user','postgres',$pg.Id,'/bin/sh','-c',$TcpPsql) -InputText ($begin+[char]10+$guard+[char]10+$Statement+[char]10+'COMMIT;')
}
function WaitPostgresTcp {
    $pg=Container 'postgres';$deadline=[DateTime]::UtcNow.AddSeconds(60)
    do {
        $output=@(& docker exec --user postgres $pg.Id pg_isready -h 127.0.0.1 -p 5432 -U gomove_demo_bootstrap -d gomove_demo_ci -t 2 2>&1)
        $code=$LASTEXITCODE
        if($code -eq 0){break}
        if($code -notin @(1,2) -or [DateTime]::UtcNow -ge $deadline){throw 'PostgreSQL TCP readiness failed/timed out'}
        $pg=Container 'postgres'
        if($pg.State.Status -ne 'running' -or $pg.State.OOMKilled){throw 'PostgreSQL stopped/OOM'}
        Start-Sleep -Milliseconds 500
    }while($true)
    if((Sql 'SELECT 1;').Trim() -ne '1'){throw 'Authenticated TCP SELECT 1 failed'}
}
function ImageGate {
    $image=Native docker @('image','inspect','--format','{{json .}}',$Image)|ConvertFrom-Json -AsHashtable
    if($image.Id -ne $Image -or $image.Os -ne 'linux' -or $image.Architecture -ne 'amd64' -or $image.Config.User -ne '10001:10001' -or
       $image.Config.Labels['org.opencontainers.image.revision'] -ne $Revision -or $image.Config.Labels['gomove.jar.sha256'] -ne $script:DemoState.steps.BuildJar.data.sha256){throw 'New image provenance mismatch'}
    @{id=$image.Id;revision=$Revision;jarSha256=$image.Config.Labels['gomove.jar.sha256'];os=$image.Os;architecture=$image.Architecture}
}
function ComposeGate {
    $dataRoot=TrustedPath $env:DEMO_OSRM_DATA_DIR
    foreach($file in @('hanoi.osrm.properties','hanoi.osrm.cells','hanoi.osrm.partition','hanoi.osrm.mldgr')){
        $dataFile=Join-Path $dataRoot $file
        if(!(Test-Path $dataFile -PathType Leaf) -or (Get-Item $dataFile).Length -le 0){throw 'Missing reviewed OSRM MLD data'}
    }
    $cfg=Compose @('config','--format','json')|ConvertFrom-Json -AsHashtable
    if($cfg.name -ne $Project -or $cfg.services.backend.environment.GOMOVE_DISPATCH_ENABLED -ne 'false' -or
       $cfg.services.backend.environment.SPRING_DATASOURCE_URL -ne 'jdbc:postgresql://postgres:5432/gomove_demo_ci' -or
       @($cfg.services.backend.ports).Count -ne 1 -or $cfg.services.backend.ports[0].host_ip -ne '127.0.0.1' -or [int]$cfg.services.backend.ports[0].published -ne 18094 -or
       $cfg.services.postgres.ContainsKey('ports') -or $cfg.services.osrm.ContainsKey('ports') -or !$cfg.networks.private.internal -or
       @($cfg.volumes.Values|Where-Object external).Count -or @($cfg.networks.Values|Where-Object external).Count -or !$cfg.services.osrm.volumes[0].read_only){throw 'Unsafe isolated staging Compose'}
    if($cfg.networks.private.name -ne ($Project+'_private') -or $cfg.networks.ingress.name -ne ($Project+'_ingress') -or
       $cfg.volumes.postgres_data.name -ne ($Project+'_postgres_data') -or
       @($cfg.services.postgres.networks.Keys).Count -ne 1 -or !$cfg.services.postgres.networks.ContainsKey('private') -or
       @($cfg.services.osrm.networks.Keys).Count -ne 1 -or !$cfg.services.osrm.networks.ContainsKey('private') -or
       @($cfg.services.backend.networks.Keys).Count -ne 2 -or !$cfg.services.backend.networks.ContainsKey('private') -or !$cfg.services.backend.networks.ContainsKey('ingress') -or
       $cfg.services.backend.environment.SPRING_PROFILES_ACTIVE -ne 'container' -or $cfg.services.backend.environment.SPRING_DATASOURCE_USERNAME -ne 'gomove_demo_app' -or
       $cfg.services.postgres.environment.POSTGRES_DB -ne 'gomove_demo_ci' -or $cfg.services.backend.user -ne '10001:10001' -or !$cfg.services.backend.read_only){throw 'Resource identity/profile/network guard failed'}
    if((TrustedPath $cfg.services.osrm.volumes[0].source) -ne $dataRoot){throw 'OSRM dataset mount changed'}
    foreach($secret in $cfg.secrets.Values){if(!(IsWithin $secret.file $SecretRoot)){throw 'Secret source outside dedicated directory'}}
}
$priorEnvironment=@{}
try {
    if($Action -eq 'StaticPreflight'){
        $Source=FullPath (Split-Path $PSScriptRoot -Parent)
        $Project='gomove-demo-ci-static-preflight'
        $EmptyEnv=[IO.Path]::GetTempFileName()
        $SecretRoot=Join-Path ([IO.Path]::GetTempPath()) ('gomove-demo-unprovisioned-'+[guid]::NewGuid().ToString('N'))
        foreach($name in @('DEMO_IMAGE','DEMO_SECRET_DIR','DEMO_OSRM_DATA_DIR')){$priorEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
        $env:DEMO_IMAGE='gomove-demo-ci:static-not-built';$env:DEMO_SECRET_DIR=$SecretRoot;$env:DEMO_OSRM_DATA_DIR='D:\GoMove-routing'
        ComposeGate
        $os=Get-CimInstance Win32_OperatingSystem
        @{configuration='STATIC_VERIFIED_ONLY';configHashes=(ConfigHashes);compose='PASS';runtimeResourceGate=(([long]$os.FreePhysicalMemory*1024)-ge 6GB);availableBytes=([long]$os.FreePhysicalMemory*1024);buildStarted=$false;deployStarted=$false}|ConvertTo-Json -Depth 5
        exit 0
    }
    ContextGate
    $Revision=$env:DEMO_COMMIT_SHA.ToLowerInvariant()
    $Run=Split-Path $Source -Parent;$Evidence=Join-Path $Run 'evidence';$StatePath=Join-Path $Evidence 'state.json'
    $Project='gomove-demo-ci-b'+$env:BUILD_NUMBER+'-'+$Revision.Substring(0,12)
    $SecretRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('GoMove\JenkinsDemoStaging\'+$Project)
    $EmptyEnv=Join-Path $Run 'empty.env'
    foreach($name in @('DEMO_IMAGE','DEMO_SECRET_DIR','DEMO_OSRM_DATA_DIR')){$priorEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
    $env:DEMO_SECRET_DIR=$SecretRoot;$env:DEMO_OSRM_DATA_DIR=TrustedPath $env:OSRM_DATA_DIR
    $env:DEMO_IMAGE='gomove-demo-ci:pending-b'+$env:BUILD_NUMBER
    SourceGate
    if($Action -eq 'Init'){
        ResourceGate
        if(Test-Path $Evidence){throw 'Refuse existing build evidence'}
        New-Item -ItemType Directory -Path $Evidence|Out-Null
        [IO.File]::WriteAllText($EmptyEnv,'',[Text.UTF8Encoding]::new($false))
        $script:DemoState=@{sourceRevision=$Revision;repository=$RepositoryUrl;job=$env:JOB_NAME;buildNumber=$env:BUILD_NUMBER;pushCauseVerified=$true;configHashes=(ConfigHashes);steps=@{};protectedBefore=(ProtectedSnapshot)}
        Record Init @{source='GITHUB_SCM';revision=$Revision;buildUrl=$env:BUILD_URL}
        exit 0
    }
    $script:DemoState=Get-Content -LiteralPath $StatePath -Raw|ConvertFrom-Json -AsHashtable
    if($script:DemoState.sourceRevision -ne $Revision){throw 'Build state revision mismatch'}
    $hashes=ConfigHashes
    foreach($key in $hashes.Keys){if($hashes[$key] -ne $script:DemoState.configHashes[$key]){throw 'CI source changed after checkout'}}
    if($script:DemoState.steps.BuildImage){$Image=$script:DemoState.steps.BuildImage.data.id;$env:DEMO_IMAGE=$Image}
    switch($Action){
        Restore {
            ResourceGate
            Push-Location (Join-Path $Source 'backend');try{Native '.\mvnw.cmd' @('-B','-ntp','dependency:go-offline') -Show|Out-Null}finally{Pop-Location}
            ResourceGate
            Push-Location (Join-Path $Source 'mobile');try{Native flutter @('pub','get','--enforce-lockfile') -Show|Out-Null}finally{Pop-Location}
            Record Restore @{exitCode=0}
        }
        Validate {
            ResourceGate
            Push-Location (Join-Path $Source 'mobile');try{Native flutter @('analyze','--no-pub') -Show|Out-Null}finally{Pop-Location}
            ComposeGate
            Record Validate @{flutterAnalyze='PASS';compose='PASS';exitCode=0}
        }
        FlutterTests {
            ResourceGate
            Push-Location (Join-Path $Source 'mobile');try{$output=Native flutter @('test','--no-pub','--concurrency=1') -Show}finally{Pop-Location}
            $totals=[regex]::Matches($output,'\+(\d+)(?:\s+~\d+)?:\s+All tests passed!')
            if(!$totals.Count){throw 'Actual Flutter test count missing'}
            Record FlutterTests @{tests=[int]$totals[-1].Groups[1].Value;failures=0;exitCode=0}
        }
        BackendTests {
            ResourceGate;$failure=$null
            Push-Location (Join-Path $Source 'backend')
            try{Native '.\mvnw.cmd' @('-B','-ntp','-DforkCount=1','-DreuseForks=true','-Djunit.jupiter.execution.parallel.enabled=false','-DargLine=-Xmx768m -XX:MaxMetaspaceSize=256m -XX:ActiveProcessorCount=2','clean','test') -Show|Out-Null}catch{$failure=$_}finally{Pop-Location}
            $xmlFiles=@(Get-ChildItem (Join-Path $Source 'backend\target\surefire-reports') -Filter 'TEST-*.xml' -File -ErrorAction SilentlyContinue)
            if(!$xmlFiles.Count){throw 'Missing Surefire results'}
            $counts=@{tests=0;failures=0;errors=0;skipped=0;exitCode=$(if($failure){1}else{0})}
            foreach($file in $xmlFiles){[xml]$xml=[IO.File]::ReadAllText($file.FullName);foreach($key in @('tests','failures','errors','skipped')){$counts[$key]+=[int]$xml.testsuite.GetAttribute($key)}}
            Record BackendTests $counts
            if($failure){throw $failure}
            if(!$counts.tests -or $counts.failures -or $counts.errors){throw 'Backend tests failed'}
        }
        BuildJar {
            ResourceGate
            if(!$script:DemoState.steps.FlutterTests -or $script:DemoState.steps.BackendTests.data.exitCode -ne 0){throw 'Mandatory CI tests not passed'}
            Push-Location (Join-Path $Source 'backend');try{Native '.\mvnw.cmd' @('-B','-ntp','-DskipTests','package') -Show|Out-Null}finally{Pop-Location}
            $jars=@(Get-ChildItem (Join-Path $Source 'backend\target') -File -Filter '*.jar'|Where-Object Name -notmatch '(sources|javadoc)\.jar$')
            if($jars.Count -ne 1){throw 'Expected one packaged application JAR'}
            $context=Join-Path $Run 'image-context'
            if(Test-Path $context){throw 'Build context already exists'}
            New-Item -ItemType Directory -Path (Join-Path $context 'health')|Out-Null
            [IO.File]::Copy($jars[0].FullName,(Join-Path $Evidence 'app.jar'),$false)
            [IO.File]::Copy($jars[0].FullName,(Join-Path $context 'app.jar'),$false)
            [IO.File]::Copy((Join-Path $Source 'ci\Dockerfile.demo'),(Join-Path $context 'Dockerfile'),$false)
            [IO.File]::WriteAllLines((Join-Path $context '.dockerignore'),@('*','!Dockerfile','!app.jar','!health/','!health/**'))
            Native javac @('-d',(Join-Path $context 'health'),(Join-Path $Source 'backend\docker\HealthProbe.java'))|Out-Null
            Record BuildJar @{sha256=(HashFile (Join-Path $Evidence 'app.jar'));revision=$Revision;origin='BUILT_BY_THIS_JENKINS_RUN';exitCode=0}
        }
        BuildImage {
            ResourceGate
            if(!$script:DemoState.steps.BuildJar){throw 'No newly built JAR'}
            $context=Join-Path $Run 'image-context'
            if((HashFile (Join-Path $context 'app.jar')) -ne $script:DemoState.steps.BuildJar.data.sha256){throw 'Staged JAR changed'}
            foreach($file in Get-ChildItem $context -File -Recurse){
                $relative=[IO.Path]::GetRelativePath($context,$file.FullName)
                if($relative -notin @('Dockerfile','app.jar','.dockerignore') -and $relative -notmatch '^health[\\/][A-Za-z0-9_$]+\.class$'){throw 'Unexpected file in minimal Docker build context'}
            }
            # Fetch only the immutable official runtime base; this is not an application-image reuse.
            Native docker @('pull','--platform','linux/amd64','eclipse-temurin:21-jre@sha256:0b99b3376fbb50dbf9c0af8535fdd5b8eb0d3fdfc8b1e4967f383b6919f6901a') -Show|Out-Null
            $tag='gomove-demo-ci:'+ $Revision.Substring(0,12)+'-b'+$env:BUILD_NUMBER
            $iid=Join-Path $Evidence 'image-id'
            Native docker @('build','--platform','linux/amd64','--pull=false','--network','none','--label',('org.opencontainers.image.revision='+$Revision),'--label',('org.opencontainers.image.source='+$RepositoryUrl),'--label',('gomove.jar.sha256='+$script:DemoState.steps.BuildJar.data.sha256),'--label',('gomove.jenkins.build='+$env:BUILD_NUMBER),'--iidfile',$iid,'-t',$tag,(Join-Path $Run 'image-context')) -Show|Out-Null
            $Image=[IO.File]::ReadAllText($iid).Trim()
            if($Image -notmatch '^sha256:[a-f0-9]{64}$'){throw 'Missing new image ID'}
            Record BuildImage @{id=$Image;tag=$tag;revision=$Revision;origin='DOCKER_BUILD_THIS_RUN';exitCode=0}
        }
        VerifyImage {
            $proof=ImageGate
            $auditName=$Project+'-artifact-audit'
            if(Native docker @('ps','-a','--filter',('name=^/'+$auditName+'$'),'--format','{{.ID}}')){throw 'Artifact audit container already exists'}
            $audit=Native docker @('create','--name',$auditName,'--network','none','--read-only','--label',('gomove.demo.audit='+$Project),'--entrypoint','/bin/true',$Image)
            Native docker @('cp',($audit+':/app/app.jar'),(Join-Path $Evidence 'image-app.jar'))|Out-Null
            if((HashFile (Join-Path $Evidence 'image-app.jar')) -ne $script:DemoState.steps.BuildJar.data.sha256){throw 'Image JAR differs from stage06 artifact'}
            Record VerifyImage @{image=$proof;actualImageJarSha256=(HashFile (Join-Path $Evidence 'image-app.jar'));auditContainerId=$audit;exitCode=0}
        }
        Deploy {
            ResourceGate
            if(!$script:DemoState.steps.VerifyImage){throw 'No image verification'}
            FreePort 18094
            foreach($kind in @('volume','network')){if(Native docker @($kind,'ls','--filter',('name='+$Project),'--format','{{.Name}}')){throw 'Existing staging volume/network'}}
            if(Native docker @('ps','-a','--filter',('label=com.docker.compose.project='+$Project),'--format','{{.ID}}')){throw 'Existing staging project'}
            if(Test-Path $SecretRoot){throw 'Refuse existing secret directory'}
            New-Item -ItemType Directory -Path $SecretRoot|Out-Null
            $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            Native icacls @($SecretRoot,'/inheritance:r','/grant:r',('*'+$sid+':(OI)(CI)F'),'*S-1-5-18:(OI)(CI)F')|Out-Null
            foreach($name in @('bootstrap-db-password','app-db-password','JWT_SECRET')){
                $bytes=[Security.Cryptography.RandomNumberGenerator]::GetBytes(48)
                $stream=[IO.File]::Open((Join-Path $SecretRoot $name),[IO.FileMode]::CreateNew)
                try{$value=[Text.Encoding]::UTF8.GetBytes([Convert]::ToBase64String($bytes));$stream.Write($value,0,$value.Length)}finally{$stream.Dispose()}
                [Array]::Clear($bytes,0,$bytes.Length);[Array]::Clear($value,0,$value.Length)
            }
            ComposeGate
            $probeName=$Project+'-secret-probe'
            Native docker @('run','--name',$probeName,'--pull','never','--network','none','--read-only','--user','10001:10001','--memory','128m','--entrypoint','/bin/sh','--label',('gomove.demo.probe='+$Project),
                '--mount',('type=bind,src='+(Join-Path $SecretRoot 'JWT_SECRET')+',dst=/run/secrets/JWT_SECRET,readonly'),
                '--mount',('type=bind,src='+(Join-Path $SecretRoot 'app-db-password')+',dst=/run/secrets/spring.datasource.password,readonly'),
                $Image,'-c','test -r /run/secrets/JWT_SECRET && test -s /run/secrets/JWT_SECRET && test -r /run/secrets/spring.datasource.password && test -s /run/secrets/spring.datasource.password')|Out-Null
            Record SecretProbe @{containerName=$probeName;uid10001Readable=$true;retainedForAudit=$true;exitCode=0}
            Compose @('up','-d','--no-deps','--no-build','--pull','never','postgres')|Out-Null
            $pg=WaitHealthy 'postgres';WaitPostgresTcp
            if([int](Sql "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename IN ('users','bookings','flyway_schema_history');") -ne 0){throw 'Target DB not empty'}
            Sql @'
DO $setup$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gomove_demo_app') THEN RAISE EXCEPTION 'App role already exists'; END IF;
 EXECUTE format('CREATE ROLE gomove_demo_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD %L', btrim(pg_read_file('/run/secrets/app-db-password')));
END $setup$;
ALTER DATABASE gomove_demo_ci OWNER TO gomove_demo_app;
ALTER SCHEMA public OWNER TO gomove_demo_app;
'@ -Write|Out-Null
            Compose @('up','-d','--no-deps','--no-build','--pull','never','osrm')|Out-Null
            $osrm=WaitHealthy 'osrm'
            Compose @('up','-d','--no-deps','--no-build','--pull','never','backend')|Out-Null
            $backend=WaitHealthy 'backend'
            Record Deploy @{project=$Project;backendId=$backend.Id;postgresId=$pg.Id;osrmId=$osrm.Id;port=18094;worker='OFF';exitCode=0}
        }
        Smoke {
            if(!$script:DemoState.steps.Deploy){throw 'No actual deployment'}
            $http=@(HttpUp '/actuator/health';HttpUp '/actuator/health/readiness')
            $backend=Container 'backend';$pg=Container 'postgres';$osrm=Container 'osrm'
            if($backend.Image -ne $Image -or $backend.Config.Env -notcontains 'GOMOVE_DISPATCH_ENABLED=false' -or $backend.Config.Env -notcontains 'SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/gomove_demo_ci'){throw 'Actual runtime image/config mismatch'}
            if(@($pg.Mounts|Where-Object Type -eq 'volume')[0].Name -ne ($Project+'_postgres_data')){throw 'Wrong staging volume'}
            $private=@($pg.NetworkSettings.Networks.Keys)
            if($private.Count -ne 1 -or $private[0] -ne ($Project+'_private') -or @($osrm.NetworkSettings.Networks.Keys).Count -ne 1){throw 'Wrong private network'}
            $ip=$backend.NetworkSettings.Networks[$private[0]].IPAddress
            $db=Sql ("SELECT json_build_object('database',current_database(),'version',(SELECT max(version::int) FROM flyway_schema_history),'migrationCount',(SELECT count(*) FROM flyway_schema_history),'success',(SELECT bool_and(success) FROM flyway_schema_history),'jdbcExpected',(SELECT bool_and(host(client_addr)='"+$ip+"') FROM pg_stat_activity WHERE usename='gomove_demo_app'),'leastPrivilege',(SELECT NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole FROM pg_roles WHERE rolname='gomove_demo_app'));")|ConvertFrom-Json -AsHashtable
            $migrations=@(Get-ChildItem (Join-Path $Source 'backend\src\main\resources\db\migration') -File|Where-Object Name -match '^V[0-9]+__')
            $maxMigration=($migrations|ForEach-Object{[int]([regex]::Match($_.Name,'^V([0-9]+)__').Groups[1].Value)}|Measure-Object -Maximum).Maximum
            if($db.database -ne 'gomove_demo_ci' -or $db.version -ne $maxMigration -or $db.migrationCount -ne $migrations.Count -or !$db.success -or !$db.jdbcExpected -or !$db.leastPrivilege){throw 'Flyway/JDBC/role mismatch'}
            $tables=(Sql "SELECT json_agg(c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p') AND c.relname <> 'flyway_schema_history' AND NOT EXISTS(SELECT 1 FROM pg_depend d WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e');")|ConvertFrom-Json
            $rows=@{};foreach($table in $tables){if($table -notmatch '^[a-z_]+$'){throw 'Unexpected table identifier'};$rows[$table]=[long](Sql ("SELECT count(*) FROM "+$table+";"))}
            if(@($rows.Values|Where-Object{$_ -ne 0}).Count){throw 'Unexpected business rows in CI staging'}
            Native docker @('exec','--user','10001:10001',$backend.Id,'java','-Xmx32m','-cp','/app/health','HealthProbe','http://osrm:5000/route/v1/driving/105.8524,21.0287;105.8576,21.0245?overview=false','"code":"Ok"')|Out-Null
            $logs=Native docker @('logs',$backend.Id)
            if($logs -notmatch '(?s)DispatchWorker:\s+Did not match:\s+- @ConditionalOnProperty \(gomove\.dispatch\.enabled=true\) found different value in property ''enabled'''){throw 'Effective Worker OFF not proven'}
            $after=ProtectedSnapshot
            foreach($name in $script:DemoState.protectedBefore.Keys){if($after[$name] -ne $script:DemoState.protectedBefore[$name]){throw 'Protected environment changed'}}
            Record Smoke @{http=$http;database=$db;tableRows=$rows;osrmHttpStatus=200;osrmCode='Ok';worker='OFF';protectedUnchanged=$true;image=(ImageGate);exitCode=0}
            $script:DemoState.result='JENKINS_DEMO_STAGING_PASS';SaveState
        }
    }
    exit 0
}catch{
    if($null -ne $script:DemoState){$script:DemoState.result='FAILURE';$script:DemoState.failedAction=$Action;$script:DemoState.error=SafeLine $_.Exception.Message;SaveState}
    Write-Error ('Demo '+$Action+': '+(SafeLine $_.Exception.Message)) -ErrorAction Continue
    if($_.Exception.Message.StartsWith('RESOURCE_GATE:')){exit 42}
    exit 1
}finally{
    foreach($name in $priorEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$priorEnvironment[$name],'Process')}
    if($Action -eq 'StaticPreflight' -and $EmptyEnv -and (Test-Path $EmptyEnv) -and (Get-Item $EmptyEnv).Length -eq 0 -and (IsWithin $EmptyEnv ([IO.Path]::GetTempPath()))){[IO.File]::Delete($EmptyEnv)}
}
