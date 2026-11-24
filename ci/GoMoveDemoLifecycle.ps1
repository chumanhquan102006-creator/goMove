# Dot-sourced by Invoke-GoMoveDemo.ps1; no work is performed on import.
# The registry contains identities and health evidence, never secret values.
function DemoHome { Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData/Local/GoMove/JenkinsPhase5/controller-20261123-df0804b/home' }
function DemoRegistryRoot { Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData/Local/GoMove/JenkinsDemoReleases' }
function DemoRegistryAcl([string]$Root) {
    $allowed=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18')
    $acl=Get-Acl -LiteralPath $Root
    if(!$acl.AreAccessRulesProtected){throw 'Registry ACL must disable inheritance'}
    foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed){throw 'Registry ACL grants access outside controller account/SYSTEM'}
    }
}
function DemoJsonHash($Value) { HashBytes ([Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 30 -Compress))) }
function DemoReadJson([string]$Path) { [IO.File]::ReadAllText($Path)|ConvertFrom-Json -AsHashtable }
function DemoContainerToken([string]$BuildNumber,$Transaction) {
    # Every Jenkins action is a new pwsh process. Compose ps/config also need interpolation;
    # Smoke must reuse the journaled token, never depend on the Deploy process environment.
    if($Transaction){
        if($Transaction.build -ne $BuildNumber -or !$Transaction.candidate.token){throw 'Wrong transaction token owner'}
        return $Transaction.candidate.token
    }
    'preflight-b'+$BuildNumber
}
function DemoWriteJson([string]$Path,$Value) {
    # Same-directory rename is atomic. Flush data before publishing either registry or journal.
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 40))
    $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
    [IO.File]::Move($temp,$Path,$true)
}
function DemoOpenRegistry {
    $root=DemoRegistryRoot
    if(!(Test-Path -LiteralPath $root)){
        New-Item -ItemType Directory -Path $root|Out-Null
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Native icacls @($root,'/inheritance:r','/grant:r',('*'+$sid+':(OI)(CI)F'),'*S-1-5-18:(OI)(CI)F')|Out-Null
    }
    if((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Registry must not be a reparse point'}
    DemoRegistryAcl $root
    # Exclusive OS lock, also released if the process dies. A journal is never cleared by locking.
    [IO.File]::Open((Join-Path $root 'deployment.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
}
function DemoSaveRegistry($Registry) { DemoWriteJson (Join-Path (DemoRegistryRoot) 'registry.json') $Registry }
function DemoLoadRegistry {
    $path=Join-Path (DemoRegistryRoot) 'registry.json'
    if(!(Test-Path -LiteralPath $path)){throw 'Registry missing; run AdoptBaseline explicitly before another deployment'}
    $r=DemoReadJson $path
    if($r.schema -ne 1 -or $r.job -ne 'GoMove-GitHub-Demo-CI' -or $r.home -ne (DemoHome) -or !$r.ContainsKey('active') -or !$r.ContainsKey('transaction')){throw 'Invalid release registry'}
    if($r.active){DemoReleaseShape $r.active}
    if($r.transaction){
        $t=$r.transaction
        if($t.phase -notin @('Preparing','Prepared','StoppingPrevious','StartingCandidate','AwaitingSmoke','RollingBack','RollbackFailed') -or
           $t.build -ne $t.candidate.build -or !$t.protected -or !$t.excludedProjects){throw 'Invalid durable transaction'}
        DemoReleaseShape $t.candidate
        if((DemoJsonHash $t.previous) -ne (DemoJsonHash $r.active)){throw 'Active release and transaction disagree'}
    }
    $r
}
function DemoReleaseShape($Release) {
    if($Release.revision -notmatch '^[a-f0-9]{40}$' -or [string]$Release.build -notmatch '^[1-9][0-9]{0,8}$' -or
       $Release.project -cne ('gomove-demo-ci-b'+$Release.build+'-'+$Release.revision.Substring(0,12)) -or
       $Release.image -notmatch '^sha256:[a-f0-9]{64}$' -or $Release.jar -notmatch '^[a-f0-9]{64}$' -or
       $Release.secretRoot -ne (Join-Path (Split-Path (DemoRegistryRoot)) ('JenkinsDemoStaging/'+$Release.project))){throw 'Invalid CI release identity'}
}
function DemoInspect([string]$Kind,[string]$Identity) {
    $inspectArgs=if($Kind -eq 'container'){@('inspect','--format','{{json .}}',$Identity)}else{@($Kind,'inspect','--format','{{json .}}',$Identity)}
    Native docker $inspectArgs|ConvertFrom-Json -AsHashtable
}
function DemoProjectIds([string]$ProjectName) {
    $text=Native docker @('ps','-a','--no-trunc','--filter',('label=com.docker.compose.project='+$ProjectName),'--format','{{.ID}}')
    @($text -split '\r?\n'|Where-Object{$_})
}
function DemoRuntimeIdentity($Metadata) {
    # Keep an exact, stable, non-secret projection; do not persist Config.Env or health log bodies.
    [ordered]@{id=$Metadata.Id;created=$Metadata.Created;image=$Metadata.Image;labels=$Metadata.Config.Labels;
        mounts=@($Metadata.Mounts|Sort-Object Destination|ForEach-Object{[ordered]@{type=$_.Type;name=$_.Name;source=$_.Source;destination=$_.Destination;rw=$_.RW}});
        networks=@($Metadata.NetworkSettings.Networks.Keys|Sort-Object);
        networkMode=$Metadata.HostConfig.NetworkMode;ports=$Metadata.HostConfig.PortBindings;user=$Metadata.Config.User;readOnly=$Metadata.HostConfig.ReadonlyRootfs}
}
function DemoResourceIdentity($Metadata,[string]$Kind) {
    [ordered]@{name=$Metadata.Name;id=$Metadata.Id;created=$(if($Kind -eq 'network'){$Metadata.Created}else{$Metadata.CreatedAt});
        labels=$Metadata.Labels;driver=$Metadata.Driver;internal=$Metadata.Internal;mountpoint=$Metadata.Mountpoint;options=$Metadata.Options}
}
function DemoCheckContainer($Release,[string]$Service,$Metadata) {
    DemoReleaseShape $Release
    $labels=$Metadata.Config.Labels
    if($Metadata.Id -notmatch '^[a-f0-9]{64}$' -or $labels['com.docker.compose.project'] -cne $Release.project -or
       $labels['com.docker.compose.service'] -cne $Service -or $labels['com.docker.compose.oneoff'] -ne 'False' -or
       $labels['com.docker.compose.container-number'] -ne '1'){throw 'Container project/service/identity rejected'}
    if($Release.token -and $labels['gomove.demo.transaction'] -cne $Release.token){throw 'Candidate creation token mismatch'}
    $expectedImage=switch($Service){
        backend {$Release.image}
        postgres {'sha256:94146ac37bc61e2322f88016056c5920729cb8c64c8542ed590af8fc2abdac07'}
        osrm {'sha256:55dbfd47d984c2cacd64e32901b4321c86b5ec761438e69aa053dc78698a786f'}
        default {throw 'Unsupported CI service'}
    }
    if($Metadata.Image -cne $expectedImage){throw 'Release image mismatch'}
    $keys=@($Metadata.NetworkSettings.Networks.Keys|Sort-Object)
    $expected=@($Release.project+'_private');if($Service -eq 'backend'){$expected=@(($Release.project+'_ingress'),($Release.project+'_private'))}
    if(($keys -join '|') -cne ($expected -join '|')){throw 'Release network mismatch'}
    $ports=$Metadata.HostConfig.PortBindings
    if($Service -eq 'backend'){
        if(@($ports.Keys).Count -ne 1 -or @($ports['8080/tcp']).Count -ne 1 -or $ports['8080/tcp'][0].HostIp -ne '127.0.0.1' -or $ports['8080/tcp'][0].HostPort -ne '18094' -or
           $Metadata.Config.User -ne '10001:10001' -or !$Metadata.HostConfig.ReadonlyRootfs -or
           $Metadata.Config.Env -notcontains 'GOMOVE_DISPATCH_ENABLED=false' -or
           $Metadata.Config.Env -notcontains 'SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/gomove_demo_ci' -or
           $labels['org.opencontainers.image.revision'] -cne $Release.revision -or $labels['gomove.jar.sha256'] -cne $Release.jar){throw 'Private backend/port/provenance guard failed'}
    }elseif(@($ports.Keys).Count){throw 'Private service exposes a host port'}
    $mounts=@($Metadata.Mounts)
    if($Service -eq 'postgres'){
        $v=@($mounts|Where-Object Type -eq 'volume')
        if($v.Count -ne 1 -or $v[0].Name -cne ($Release.project+'_postgres_data') -or $v[0].Destination -ne '/var/lib/postgresql/data'){throw 'Database volume mismatch'}
    }
    foreach($mount in $mounts|Where-Object Destination -like '/run/secrets/*'){
        if($mount.Type -ne 'bind' -or $mount.RW -or !(IsWithin $mount.Source $Release.secretRoot)){throw 'Secret mount outside release'}
    }
}
function DemoCaptureRelease($Release,$ExpectedIds) {
    DemoReleaseShape $Release
    $actual=@(DemoProjectIds $Release.project|Sort-Object)
    $expected=@($ExpectedIds.Values|Sort-Object)
    if($actual.Count -ne 3 -or ($actual -join '|') -cne ($expected -join '|')){throw 'Missing or ambiguous project container membership'}
    $Release.containers=@{}
    foreach($service in @('postgres','osrm','backend')){
        $m=DemoInspect container $ExpectedIds[$service];DemoCheckContainer $Release $service $m
        $Release.containers[$service]=DemoRuntimeIdentity $m
    }
    $Release.networks=@{}
    foreach($key in @('private','ingress')){
        $name=$Release.project+'_'+$key;$m=DemoInspect network $name
        if($m.Name -cne $name -or $m.Id -notmatch '^[a-f0-9]{64}$' -or $m.Labels['com.docker.compose.project'] -cne $Release.project -or
           $m.Labels['com.docker.compose.network'] -cne $key -or $m.Driver -ne 'bridge' -or [bool]$m.Internal -ne ($key -eq 'private')){throw 'Network identity rejected'}
        $Release.networks[$key]=DemoResourceIdentity $m network
    }
    $m=DemoInspect volume ($Release.project+'_postgres_data')
    if($m.Name -cne ($Release.project+'_postgres_data') -or $m.Labels['com.docker.compose.project'] -cne $Release.project -or
       $m.Labels['com.docker.compose.volume'] -ne 'postgres_data' -or $m.Driver -ne 'local' -or !$m.CreatedAt){throw 'Volume identity rejected'}
    $Release.volume=DemoResourceIdentity $m volume
    # Also bind each container network endpoint to the captured network ID.
    DemoAssertRelease $Release
    $Release
}
function DemoAssertRelease($Release) {
    DemoReleaseShape $Release
    if(@($Release.containers.Keys).Count -ne 3 -or @($Release.networks.Keys).Count -ne 2 -or !$Release.volume){throw 'Incomplete release manifest'}
    $ids=@(DemoProjectIds $Release.project|Sort-Object)
    if(($ids -join '|') -cne (@($Release.containers.Values.id|Sort-Object) -join '|')){throw 'Project membership changed'}
    foreach($service in @('postgres','osrm','backend')){
        $saved=$Release.containers[$service];$m=DemoInspect container $saved.id;DemoCheckContainer $Release $service $m
        if((DemoJsonHash (DemoRuntimeIdentity $m)) -ne (DemoJsonHash $saved)){throw 'Container identity changed'}
        foreach($n in $saved.networks){
            $key=$n.Substring($Release.project.Length+1);$endpoint=$m.NetworkSettings.Networks[$n].NetworkID
            # Docker may not assign endpoint IDs to a never-started container. The immutable
            # network resource is still verified below, before any start or stop.
            if(($endpoint -and $Release.networks[$key].id -cne $endpoint) -or (!$endpoint -and $m.State.Status -eq 'running')){throw 'Network endpoint identity mismatch'}
        }
    }
    foreach($key in @('private','ingress')){
        if((DemoJsonHash (DemoResourceIdentity (DemoInspect network $Release.networks[$key].id) network)) -ne (DemoJsonHash $Release.networks[$key])){throw 'Network replaced'}
    }
    if((DemoJsonHash (DemoResourceIdentity (DemoInspect volume $Release.volume.name) volume)) -ne (DemoJsonHash $Release.volume)){throw 'Volume replaced'}
}
function DemoAssertPort($Owner) {
    $ids=@((Native docker @('ps','--no-trunc','--filter','publish=18094','--format','{{.ID}}')) -split '\r?\n'|Where-Object{$_})
    if($Owner){
        DemoAssertRelease $Owner
        if($ids.Count -ne 1 -or $ids[0] -cne $Owner.containers.backend.id){throw 'Port 18094 has an unverified Docker owner'}
    }else{
        if($ids.Count){throw 'Port 18094 belongs to an unknown container'}
        FreePort 18094 # Also rejects an unrelated host process.
    }
}
function DemoAssertRecoveryPort($Previous,$Candidate=$null) {
    # Prepared/partially stopped cutovers may still have the exact previous backend running.
    # Accept only a verified running backend of either release, otherwise require a free port.
    $owners=@()
    foreach($release in @($Previous,$Candidate)|Where-Object{$_}){
        DemoAssertRelease $release
        if((DemoInspect container $release.containers.backend.id).State.Status -eq 'running'){$owners+=@($release)}
    }
    if($owners.Count -gt 1){throw 'Ambiguous running release backends on port 18094'}
    if($owners.Count){DemoAssertPort $owners[0]}else{DemoAssertPort $null}
}
function DemoWaitId([string]$Id) {
    $until=[DateTime]::UtcNow.AddSeconds(150)
    do{
        $m=DemoInspect container $Id
        if($m.State.Status -ne 'running' -or $m.State.OOMKilled){throw 'Release stopped/OOM during recovery'}
        if($m.State.Health.Status -eq 'healthy'){return}
        Start-Sleep -Seconds 2
    }while([DateTime]::UtcNow -lt $until)
    throw 'Release health timeout'
}
function DemoVerifyRestored($Release) {
    DemoAssertRelease $Release;DemoAssertPort $Release
    foreach($service in @('postgres','osrm','backend')){DemoWaitId $Release.containers[$service].id}
    $http=@(HttpUp '/actuator/health';HttpUp '/actuator/health/readiness')
    @{image=$Release.image;http=$http;verifiedAt=[DateTimeOffset]::Now.ToString('o')}
}
function DemoStartVerifiedRelease($Release) {
    DemoAssertRelease $Release;DemoAssertRecoveryPort $Release
    # Reject unexpected states across the whole set before the first start.
    foreach($service in @('postgres','osrm','backend')){
        if((DemoInspect container $Release.containers[$service].id).State.Status -notin @('running','created','exited')){throw 'Unexpected active container state; refuse restore'}
    }
    $started=@()
    foreach($service in @('postgres','osrm','backend')){
        DemoAssertRelease $Release;DemoAssertRecoveryPort $Release
        $id=$Release.containers[$service].id
        $status=(DemoInspect container $id).State.Status
        if($status -in @('created','exited')){Native docker @('start',$id)|Out-Null;$started+=@($service)}
        elseif($status -ne 'running'){throw 'Active container state changed; refuse restore'}
        DemoWaitId $id
    }
    $proof=DemoVerifyRestored $Release;$proof.startedServices=$started
    $proof
}
function DemoRestoreActiveDeployment($Registry,[switch]$Confirmed) {
    if(!$Confirmed){throw 'RestoreActiveDeployment requires explicit confirmation'}
    if($Registry.transaction){throw 'Unresolved transaction; active restoration refused'}
    if(!$Registry.active){throw 'No verified active release to restore'}
    DemoAssertRelease $Registry.active;DemoAssertRecoveryPort $Registry.active
    $exclude=@($Registry.active.project);$before=ProtectedSnapshot $exclude
    $proof=DemoStartVerifiedRelease $Registry.active
    DemoAssertProtected $before $exclude
    @{status='ACTIVE_DEPLOYMENT_VERIFIED';project=$Registry.active.project;verification=$proof;protectedUnchanged=$true}
}
function DemoAssertProtected($Snapshot,[string[]]$ExcludeProjects=@()) {
    $current=ProtectedSnapshot $ExcludeProjects
    if((($current.Keys|Sort-Object) -join '|') -cne (($Snapshot.Keys|Sort-Object) -join '|')){throw 'Protected container membership changed'}
    foreach($key in $Snapshot.Keys){if($current[$key] -cne $Snapshot[$key]){throw 'Protected environment changed'}}
}
function DemoAdoptBaseline {
    $lock=DemoOpenRegistry
    try{
        $path=Join-Path (DemoRegistryRoot) 'registry.json'
        if(Test-Path -LiteralPath $path){throw 'Registry already exists; never overwrite adoption'}
        $homePath=DemoHome
        $statePath=Join-Path $homePath 'workspace/GoMove-GitHub-Demo-CI/runs/5/evidence/state.json'
        $buildPath=Join-Path $homePath 'jobs/GoMove-GitHub-Demo-CI/builds/5/build.xml'
        $state=DemoReadJson $statePath
        $buildText=[IO.File]::ReadAllText($buildPath)
        [xml]$build=($buildText -replace '^<\?xml[^?]*\?>','')
        $revision='3c068d513581c7fa3c2a68fca68d30dfe9ca047c'
        if($build.'flow-build'.result -ne 'SUCCESS' -or $build.'flow-build'.completed -ne 'true' -or $buildText -notmatch 'com.cloudbees.jenkins.GitHubPushCause' -or
           $state.buildNumber -ne '5' -or $state.sourceRevision -cne $revision -or !$state.pushCauseVerified -or $state.job -ne 'GoMove-GitHub-Demo-CI' -or
           $state.result -ne 'JENKINS_DEMO_STAGING_PASS' -or $state.steps.Smoke.data.exitCode -ne 0 -or !$state.steps.Smoke.data.protectedUnchanged -or
           $state.steps.BuildJar.data.sha256 -cne $state.steps.VerifyImage.data.actualImageJarSha256 -or
           $state.steps.BuildImage.data.id -cne $state.steps.Smoke.data.image.id -or
           $state.steps.BuildImage.data.id -cne 'sha256:832be007a4bbfe0b65a19a3da943662367b8a900a039c6d815acb15434ea8c3a' -or
           $state.steps.BuildJar.data.sha256 -cne '35773c9aad61be79b9ef9b293bcab119d9cfc15eca7709c430c231ea5c72e947'){throw 'Build #5 successful evidence not verified'}
        foreach($file in @('app.jar','image-app.jar')){
            if((HashFile (Join-Path (Split-Path $statePath) $file)) -cne $state.steps.BuildJar.data.sha256){throw 'Baseline JAR evidence changed'}
        }
        foreach($name in @('FlutterTests','BackendTests')){if($state.steps[$name].data.exitCode -ne 0 -or $state.steps[$name].data.failures){throw 'Baseline tests did not pass'}}
        $r=@{build='5';revision=$revision;project=$state.steps.Deploy.data.project;image=$state.steps.BuildImage.data.id;jar=$state.steps.BuildJar.data.sha256;
            secretRoot=(Join-Path (Split-Path (DemoRegistryRoot)) ('JenkinsDemoStaging/'+$state.steps.Deploy.data.project));token=$null;
            provenance=@{stateSha256=(HashFile $statePath);buildXmlSha256=(HashFile $buildPath)}}
        $r=DemoCaptureRelease $r @{postgres=$state.steps.Deploy.data.postgresId;osrm=$state.steps.Deploy.data.osrmId;backend=$state.steps.Deploy.data.backendId}
        $r.health=DemoVerifyRestored $r
        DemoSaveRegistry @{schema=1;job='GoMove-GitHub-Demo-CI';home=$homePath;active=$r;transaction=$null;history=@();adoptedAt=[DateTimeOffset]::Now.ToString('o')}
        @{adoptedBuild=5;project=$r.project;image=$r.image;containers=$r.containers.Values.id;runtimeModified=$false}
    }finally{$lock.Dispose()}
}
function DemoBeginTransaction($Registry,$Candidate,[string]$BuildNumber) {
    if($Registry.transaction){throw 'Unresolved deployment transaction; explicit recovery required'}
    DemoReleaseShape $Candidate
    if($Candidate.build -ne $BuildNumber -or ($Registry.active -and $Candidate.project -eq $Registry.active.project)){throw 'Candidate is not a fresh build-specific release'}
    if($Registry.active){$null=DemoVerifyRestored $Registry.active}else{DemoAssertPort $null}
    $exclude=@($Candidate.project);if($Registry.active){$exclude+=@($Registry.active.project)}
    $Registry.transaction=@{build=$BuildNumber;previous=$Registry.active;candidate=$Candidate;phase='Preparing';cutover=$false;excludedProjects=$exclude;
        startedAt=[DateTimeOffset]::Now.ToString('o');protected=(ProtectedSnapshot $exclude)}
    DemoSaveRegistry $Registry
}
function DemoStopRelease($Release) {
    # Validate the entire identity set before the first mutation, and again before each exact-ID stop.
    DemoAssertRelease $Release
    foreach($service in @('backend','osrm','postgres')){
        DemoAssertRelease $Release
        $id=$Release.containers[$service].id
        $status=(DemoInspect container $id).State.Status
        if($status -eq 'running'){Native docker @('stop','--time','30',$id)|Out-Null}
        elseif($status -notin @('exited','created')){throw 'Unexpected container state; refuse stop'}
        if((DemoInspect container $id).State.Status -notin @('exited','created')){throw 'Verified release did not stop'}
    }
}
function DemoCutover($Registry) {
    $t=$Registry.transaction
    if($t.phase -ne 'Prepared' -or !$t.candidate.containers){throw 'Candidate not durably prepared'}
    DemoAssertRelease $t.candidate
    if($t.previous){DemoAssertPort $t.previous}else{DemoAssertPort $null}
    DemoAssertProtected $t.protected $t.excludedProjects
    $t.phase='StoppingPrevious';$t.cutover=$true;DemoSaveRegistry $Registry
    if($t.previous){DemoStopRelease $t.previous}
    DemoAssertPort $null
    $t.phase='StartingCandidate';DemoSaveRegistry $Registry
}
function DemoPromote($Registry,$SmokeProof) {
    $t=$Registry.transaction
    if($t.phase -ne 'AwaitingSmoke' -or $SmokeProof.exitCode -ne 0 -or !$SmokeProof.protectedUnchanged){throw 'Smoke not passed; cannot promote'}
    DemoAssertRelease $t.candidate;DemoAssertPort $t.candidate;DemoAssertProtected $t.protected $t.excludedProjects
    DemoCompleteTransaction $Registry 'Promoted' @{promotedAt=[DateTimeOffset]::Now.ToString('o');smoke=$SmokeProof}
}
function DemoCompleteTransaction($Registry,[string]$Phase,$Completion) {
    # Publish a separate object before changing caller memory. On publication failure the
    # pending transaction, previous active pointer and history remain available for recovery.
    $next=($Registry|ConvertTo-Json -Depth 40)|ConvertFrom-Json -AsHashtable
    $completed=$next.transaction
    if(!$completed -or $Phase -notin @('Promoted','RolledBack','PreparationAbandoned')){throw 'Invalid transaction completion'}
    $completed.phase=$Phase
    foreach($key in $Completion.Keys){$completed[$key]=$Completion[$key]}
    $next.active=if($Phase -eq 'Promoted'){$completed.candidate}else{$completed.previous}
    $next.history=@($next.history)+@($completed);$next.transaction=$null
    DemoSaveRegistry $next
    foreach($key in @($Registry.Keys)){$Registry.Remove($key)}
    foreach($key in $next.Keys){$Registry[$key]=$next[$key]}
}
function DemoRollback($Registry) {
    $t=$Registry.transaction
    if(!$t){return @{status='NO_PENDING_TRANSACTION'}}
    # A partial prepare is never inferred as owned by a name alone. Keep it for explicit review.
    if(!$t.candidate.containers){throw 'Incomplete candidate identity; read-only investigation required'}
    try{
        DemoAssertProtected $t.protected $t.excludedProjects;DemoAssertRelease $t.candidate
        if($t.previous){DemoAssertRelease $t.previous}
        DemoAssertRecoveryPort $t.previous $t.candidate
        $t.phase='RollingBack';DemoSaveRegistry $Registry
        DemoStopRelease $t.candidate
        DemoAssertRecoveryPort $t.previous
        if($t.previous){
            $t.rollback=DemoStartVerifiedRelease $t.previous
        }else{$t.rollback=@{emptyStagingVerified=$true};DemoAssertPort $null}
        DemoAssertProtected $t.protected $t.excludedProjects
        DemoCompleteTransaction $Registry 'RolledBack' @{rolledBackAt=[DateTimeOffset]::Now.ToString('o')}
        @{status='ROLLED_BACK';previousProject=$(if($Registry.active){$Registry.active.project}else{$null});verification=$t.rollback}
    }catch{
        $t.phase='RollbackFailed';$t.rollbackError=SafeLine $_.Exception.Message
        $Registry.transaction=$t # Keep failure blocking even if the final rollback metadata write failed.
        DemoSaveRegistry $Registry
        throw 'Rollback not verified; preserve resources and inspect durable transaction'
    }
}
function DemoRecoverBuild($Registry,[string]$BuildNumber,[switch]$Explicit) {
    if(!$Registry.transaction){return @{status='NO_PENDING_TRANSACTION'}}
    if($Registry.transaction.build -ne $BuildNumber){throw 'Recovery belongs to another build; operator review required'}
    if($Registry.transaction.phase -eq 'RollbackFailed' -and !$Explicit){throw 'Previous rollback failed; no automatic retry'}
    if(!$Registry.transaction.candidate.containers -and $Explicit -and !$Registry.transaction.cutover){
        # Interrupted create before identity capture: never guess IDs to stop. An explicit
        # operator may retire this attempt only after proving all surviving candidates are
        # stopped and the previous release is still healthy. Preserve every resource.
        $t=$Registry.transaction;DemoAssertProtected $t.protected $t.excludedProjects
        if($t.previous){$restored=DemoVerifyRestored $t.previous}else{DemoAssertPort $null;$restored=@{emptyStagingVerified=$true}}
        $seen=@{};$partial=@{}
        foreach($id in @(DemoProjectIds $t.candidate.project)){
            $m=DemoInspect container $id;$service=$m.Config.Labels['com.docker.compose.service']
            if($service -notin @('postgres','osrm','backend') -or $seen[$service]){throw 'Ambiguous partial candidate; operator review required'}
            DemoCheckContainer $t.candidate $service $m
            if($m.State.Status -notin @('created','exited')){throw 'Partial candidate is running; no inferred stop is allowed'}
            $seen[$service]=$true;$partial[$service]=DemoRuntimeIdentity $m
        }
        DemoCompleteTransaction $Registry 'PreparationAbandoned' @{partialContainers=$partial;rollback=$restored}
        return @{status='PREPARATION_ABANDONED';runtimeModified=$false;retainedContainerCount=$partial.Count}
    }
    DemoRollback $Registry
}
