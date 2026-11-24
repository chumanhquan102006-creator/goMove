#requires -Version 7.2
# Dependency-free, isolated lifecycle regressions. Native() below never calls Docker or Jenkins.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GoMoveDemoLifecycle.ps1')
$script:realRegistrySaver=${function:DemoSaveRegistry}
function DemoSaveRegistry($Registry){
    if($script:failAllRegistryWrites -or ($script:failTerminalPublication -and !$Registry.transaction -and @($Registry.history).Count)){
        throw 'Mock durable registry publication failure'
    }
    & $script:realRegistrySaver $Registry
}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('gomove-lifecycle-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
$script:passed=0;$script:failed=0
function FullPath($Path){[IO.Path]::GetFullPath($Path).TrimEnd('\','/')}
function IsWithin($Path,$Parent){(FullPath $Path).StartsWith((FullPath $Parent)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)}
function HashBytes([byte[]]$Bytes){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
function HashFile($Path){if([IO.Path]::GetFileName($Path) -in @('app.jar','image-app.jar')){return '35773c9aad61be79b9ef9b293bcab119d9cfc15eca7709c430c231ea5c72e947'};HashBytes ([IO.File]::ReadAllBytes($Path))}
function SafeLine($Line){$Line}
function DemoHome{Join-Path $script:caseRoot 'home'}
function DemoRegistryRoot{Join-Path $script:caseRoot 'releases'}
function DemoRegistryAcl($Root){} # Runtime ACL probe is separate; mocks never alter host ACLs.
function FreePort($Port){if($script:unknownPort){throw 'Unknown host process owns port'}}
function ProtectedSnapshot($ExcludeProjects){@{platform='immutable-platform';sandbox='immutable-stopped-sandbox';manual='immutable-stopped-manual';legacy='immutable-legacy';otherCi=$script:otherCi}}
function HttpUp($Path){if($script:httpFails){throw 'Mock HTTP health failure'};@{path=$Path;httpStatus=200;status='UP'}}
function Native($File,[string[]]$Arguments){
    if($File -eq 'icacls'){return ''}
    if($File -ne 'docker'){throw 'Unexpected native command; no real processes allowed'}
    if($Arguments[0] -eq 'ps'){
        $filter=@($Arguments|Where-Object{$_ -like 'label=com.docker.compose.project=*'})
        if($filter.Count){$p=$filter[0].Substring('label=com.docker.compose.project='.Length);return (@($script:containers.Values|Where-Object{$_.Config.Labels['com.docker.compose.project'] -eq $p}|ForEach-Object Id) -join "`n")}
        if($Arguments -contains 'publish=18094'){return (@($script:containers.Values|Where-Object{$_.Config.Labels['com.docker.compose.service'] -eq 'backend' -and $_.State.Status -eq 'running'}|ForEach-Object Id) -join "`n")}
    }
    if($Arguments[0] -eq 'inspect'){$m=$script:containers[$Arguments[-1]];if(!$m){throw 'Container missing'};return ($m|ConvertTo-Json -Depth 30 -Compress)}
    if($Arguments[0] -in @('network','volume') -and $Arguments[1] -eq 'inspect'){
        $key=$Arguments[-1];$set=if($Arguments[0] -eq 'network'){$script:networks}else{$script:volumes}
        $m=@($set.Values|Where-Object{$_.Name -eq $key -or $_.Id -eq $key})
        if($m.Count -ne 1){throw 'Resource missing'};return ($m[0]|ConvertTo-Json -Depth 15 -Compress)
    }
    if($Arguments[0] -in @('stop','start')){
        $id=$Arguments[-1];$m=$script:containers[$id];if(!$m){throw 'Mutation of unknown ID rejected'}
        $service=$m.Config.Labels['com.docker.compose.service'];$project=$m.Config.Labels['com.docker.compose.project']
        if($project -notmatch '^gomove-demo-ci-b[0-9]+-[a-f0-9]{12}$'){throw 'Protected mutation rejected'}
        $script:events.Add($Arguments[0]+':'+$project+':'+$service)
        if($Arguments[0] -eq 'start' -and $script:failStart -eq $id){throw 'Mock start failure'}
        $m.State.Status=if($Arguments[0] -eq 'start'){'running'}else{'exited'}
        if($Arguments[0] -eq 'start' -and $script:changeProtectedOnStart){$script:otherCi='changed-during-start'}
        return $id
    }
    throw ('Unexpected Docker operation; no real Docker call: '+$Arguments[0])
}
function Check($Condition,[string]$Message){if(!$Condition){throw $Message}}
function Reject([scriptblock]$Body,[string]$Pattern){try{& $Body;throw 'Expected rejection was not raised'}catch{if($_.Exception.Message -notmatch $Pattern){throw}}}
function ResetCase {
    $script:caseRoot=Join-Path $testRoot ([guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path (DemoRegistryRoot)|Out-Null
    $script:containers=@{};$script:networks=@{};$script:volumes=@{};$script:events=[Collections.Generic.List[string]]::new()
    $script:otherCi='unchanged-other-ci';$script:unknownPort=$false;$script:httpFails=$false;$script:failStart=$null
    $script:failAllRegistryWrites=$false;$script:failTerminalPublication=$false;$script:changeProtectedOnStart=$false
}
function Fixture([int]$Number,[switch]$Running){
    $rev=if($Number -eq 5){'3c068d513581c7fa3c2a68fca68d30dfe9ca047c'}else{('a'*38)+$Number.ToString('00')}
    $image=if($Number -eq 5){'sha256:832be007a4bbfe0b65a19a3da943662367b8a900a039c6d815acb15434ea8c3a'}else{'sha256:'+('b'*62)+$Number.ToString('00')}
    $project='gomove-demo-ci-b'+$Number+'-'+$rev.Substring(0,12)
    $r=@{build=[string]$Number;revision=$rev;project=$project;image=$image;jar='35773c9aad61be79b9ef9b293bcab119d9cfc15eca7709c430c231ea5c72e947';token=$(if($Number -eq 5){$null}else{'token-'+$Number});secretRoot=(Join-Path (Split-Path (DemoRegistryRoot)) ('JenkinsDemoStaging/'+$project))}
    foreach($n in @('private','ingress')){
        $id=HashBytes ([Text.Encoding]::UTF8.GetBytes($project+$n))
        $script:networks[$project+'_'+$n]=@{Name=$project+'_'+$n;Id=$id;Created='2026-11-24T00:00:00Z';Labels=@{'com.docker.compose.project'=$project;'com.docker.compose.network'=$n};Driver='bridge';Internal=($n -eq 'private')}
    }
    $script:volumes[$project+'_postgres_data']=@{Name=$project+'_postgres_data';CreatedAt='2026-11-24T00:00:00Z';Labels=@{'com.docker.compose.project'=$project;'com.docker.compose.volume'='postgres_data'};Driver='local';Mountpoint='/mock/'+$project;Options=$null}
    $ids=@{}
    foreach($service in @('postgres','osrm','backend')){
        $id=HashBytes ([Text.Encoding]::UTF8.GetBytes($project+$service));$ids[$service]=$id
        $labels=@{'com.docker.compose.project'=$project;'com.docker.compose.service'=$service;'com.docker.compose.oneoff'='False';'com.docker.compose.container-number'='1'}
        if($r.token){$labels['gomove.demo.transaction']=$r.token}
        if($service -eq 'backend'){$labels['org.opencontainers.image.revision']=$rev;$labels['gomove.jar.sha256']=$r.jar}
        $net=@{};foreach($n in $(if($service -eq 'backend'){@('private','ingress')}else{@('private')})){$net[$project+'_'+$n]=@{NetworkID=$script:networks[$project+'_'+$n].Id}}
        $mounts=@();if($service -eq 'postgres'){$mounts=@(@{Type='volume';Name=$project+'_postgres_data';Source='/mock/'+$project;Destination='/var/lib/postgresql/data';RW=$true})}
        $serviceImage=switch($service){backend{$image};postgres{'sha256:94146ac37bc61e2322f88016056c5920729cb8c64c8542ed590af8fc2abdac07'};osrm{'sha256:55dbfd47d984c2cacd64e32901b4321c86b5ec761438e69aa053dc78698a786f'}}
        $ports=@{};if($service -eq 'backend'){$ports['8080/tcp']=@(@{HostIp='127.0.0.1';HostPort='18094'})}
        $script:containers[$id]=@{Id=$id;Created='2026-11-24T00:00:00Z';Image=$serviceImage;Config=@{Labels=$labels;User=$(if($service -eq 'backend'){'10001:10001'}else{''});Env=@('GOMOVE_DISPATCH_ENABLED=false','SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/gomove_demo_ci')};Mounts=$mounts;NetworkSettings=@{Networks=$net};HostConfig=@{PortBindings=$ports;ReadonlyRootfs=($service -eq 'backend');NetworkMode=$project+'_private'};State=@{Status=$(if($Running){'running'}else{'created'});Health=@{Status='healthy'};OOMKilled=$false}}
    }
    DemoCaptureRelease $r $ids
}
function Registry($Active){@{schema=1;job='GoMove-GitHub-Demo-CI';home=(DemoHome);active=$Active;transaction=$null;history=@()}}
function Prepare($Reg,$Candidate){DemoBeginTransaction $Reg $Candidate $Candidate.build;$Reg.transaction.phase='Prepared';DemoSaveRegistry $Reg}
function StartCandidate($Reg){foreach($s in @('postgres','osrm','backend')){Native docker @('start',$Reg.transaction.candidate.containers[$s].id)|Out-Null};$Reg.transaction.phase='AwaitingSmoke';DemoSaveRegistry $Reg}
function Case([string]$Name,[scriptblock]$Body){ResetCase;try{& $Body;$script:passed++;Write-Host ('PASS '+$Name)}catch{$script:failed++;Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}}
Case 'First deployment with free port promotes only after smoke' {
    $c=Fixture 6;$r=Registry $null;Prepare $r $c;DemoCutover $r;StartCandidate $r
    Check (!$r.active) 'Promoted before smoke';DemoPromote $r @{exitCode=0;protectedUnchanged=$true}
    Check ($r.active.project -eq $c.project -and !$r.transaction) 'Candidate not promoted'
}
Case 'Adopt genuine successful Build 5 evidence and exact runtime identity' {
    $old=Fixture 5 -Running;$homePath=DemoHome;$e=Join-Path $homePath 'workspace/GoMove-GitHub-Demo-CI/runs/5/evidence';$b=Join-Path $homePath 'jobs/GoMove-GitHub-Demo-CI/builds/5'
    New-Item -ItemType Directory -Path $e,$b|Out-Null
    $s=@{buildNumber='5';sourceRevision=$old.revision;job='GoMove-GitHub-Demo-CI';pushCauseVerified=$true;result='JENKINS_DEMO_STAGING_PASS';steps=@{Smoke=@{data=@{exitCode=0;protectedUnchanged=$true;image=@{id=$old.image}}};FlutterTests=@{data=@{exitCode=0;failures=0}};BackendTests=@{data=@{exitCode=0;failures=0}};BuildJar=@{data=@{sha256=$old.jar}};VerifyImage=@{data=@{actualImageJarSha256=$old.jar}};BuildImage=@{data=@{id=$old.image}};Deploy=@{data=@{project=$old.project;postgresId=$old.containers.postgres.id;osrmId=$old.containers.osrm.id;backendId=$old.containers.backend.id}}}}
    DemoWriteJson (Join-Path $e 'state.json') $s
    [IO.File]::WriteAllText((Join-Path $b 'build.xml'),'<flow-build><result>SUCCESS</result><completed>true</completed><cause>com.cloudbees.jenkins.GitHubPushCause</cause></flow-build>')
    DemoAdoptBaseline|Out-Null;$saved=DemoLoadRegistry
    Check ($saved.active.containers.backend.id -eq $old.containers.backend.id) 'Wrong adoption'
    Check ($script:events.Count -eq 0) 'Adoption mutated runtime'
    Reject {DemoAdoptBaseline} 'already exists'
}
Case 'Verified active replacement stops exact previous IDs in dependency order' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c
    Check ($script:events.Count -eq 0) 'Stopped old before cutover'
    DemoCutover $r
    Check (($script:events -join '|') -eq ('stop:'+ $old.project+':backend|stop:'+$old.project+':osrm|stop:'+$old.project+':postgres')) 'Wrong stop order'
    Check ((DemoLoadRegistry).transaction.cutover) 'Cutover not persisted'
}
Case 'Unknown Windows process occupying free staging port is rejected' {
    $c=Fixture 6;$script:unknownPort=$true;Reject {DemoBeginTransaction (Registry $null) $c '6'} 'Unknown host process';Check ($script:events.Count -eq 0) 'Mutation on unknown owner'
}
Case 'Unknown Docker owner on 18094 is rejected' {
    $old=Fixture 5 -Running;$c=Fixture 6 -Running;Reject {DemoBeginTransaction (Registry $old) $c '6'} 'unverified Docker owner';Check ($script:events.Count -eq 0) 'Unknown port owner mutated'
}
Case 'Invalid project cannot be used to stop a protected environment' {
    $old=Fixture 5 -Running;$old.project='gomove-platform';Reject {DemoStopRelease $old} 'Invalid CI release';Check (!$script:events.Count) 'Protected environment mutated'
}
Case 'Mismatching service label fails before any stop' {
    $old=Fixture 5 -Running;$script:containers[$old.containers.osrm.id].Config.Labels['com.docker.compose.service']='postgres'
    Reject {DemoStopRelease $old} 'project/service/identity';Check (!$script:events.Count) 'Partial stop on invalid set'
}
Case 'Replaced container ID fails closed' {
    $old=Fixture 5 -Running;$script:containers.Remove($old.containers.postgres.id)
    Reject {DemoStopRelease $old} 'membership changed';Check (!$script:events.Count) 'Wrong ID stopped'
}
Case 'Replaced network is rejected before mutations' {
    $old=Fixture 5 -Running;$script:networks[$old.project+'_private'].Id='f'*64
    Reject {DemoStopRelease $old} 'Network replaced|Resource missing';Check (!$script:events.Count) 'Mutation with replaced network'
}
Case 'Replaced database volume is rejected before mutations' {
    $old=Fixture 5 -Running;$script:volumes[$old.project+'_postgres_data'].CreatedAt='changed'
    Reject {DemoStopRelease $old} 'Volume replaced';Check (!$script:events.Count) 'Mutation with replaced volume'
}
Case 'Candidate image or creation token mismatch is rejected' {
    $c=Fixture 6;$script:containers[$c.containers.backend.id].Config.Labels['gomove.demo.transaction']='another-build'
    Reject {DemoAssertRelease $c} 'token mismatch';$script:containers[$c.containers.backend.id].Config.Labels['gomove.demo.transaction']=$c.token
    $script:containers[$c.containers.backend.id].Image='sha256:'+('f'*64);Reject {DemoAssertRelease $c} 'image mismatch'
}
Case 'Candidate deployment failure rolls back previous exact containers' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c;DemoCutover $r
    Native docker @('start',$c.containers.postgres.id)|Out-Null
    $result=DemoRollback $r
    Check ($result.status -eq 'ROLLED_BACK' -and $r.active.project -eq $old.project -and !$r.transaction) 'Restoration not recorded'
    Check (($script:events|Select-Object -Last 3) -join '|' -eq ('start:'+$old.project+':postgres|start:'+$old.project+':osrm|start:'+$old.project+':backend')) 'Restore dependency order wrong'
}
Case 'Smoke failure restores old release without promoting candidate' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c;DemoCutover $r;StartCandidate $r
    Reject {DemoPromote $r @{exitCode=1;protectedUnchanged=$true}} 'Smoke not passed'
    DemoRollback $r|Out-Null;Check ($r.active.project -eq $old.project) 'Failed smoke promoted candidate'
}
Case 'Rollback failure remains durable and never claims success' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c;DemoCutover $r;StartCandidate $r
    $script:failStart=$old.containers.postgres.id;Reject {DemoRollback $r} 'Rollback not verified'
    Check ((DemoLoadRegistry).transaction.phase -eq 'RollbackFailed') 'Failure journal lost'
}
Case 'Restored HTTP failure is not rollback success' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c;DemoCutover $r;StartCandidate $r
    $script:httpFails=$true;Reject {DemoRollback $r} 'Rollback not verified';Check ($r.transaction.phase -eq 'RollbackFailed') 'HTTP failure hidden'
}
Case 'Interrupted cutover is recoverable from disk by a new process' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c;DemoCutover $r
    $reloaded=DemoLoadRegistry;DemoRollback $reloaded|Out-Null
    Check (!(DemoLoadRegistry).transaction) 'Interrupted transaction not resolved'
}
Case 'Partial previous stop after interruption restores only stopped previous containers' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c
    $r.transaction.phase='StoppingPrevious';$r.transaction.cutover=$true;DemoSaveRegistry $r
    Native docker @('stop',$old.containers.backend.id)|Out-Null
    DemoRecoverBuild (DemoLoadRegistry) '6'|Out-Null
    Check (($script:events -join '|') -eq ('stop:'+$old.project+':backend|start:'+$old.project+':backend')) 'Restarted an already running service or touched unstarted candidate'
}
Case 'Unresolved transaction blocks the next deployment' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c
    Reject {DemoBeginTransaction $r (Fixture 7) '7'} 'explicit recovery required';Check (!$script:events.Count) 'Unresolved transaction mutated runtime'
}
Case 'Separate Validate and Smoke processes resolve token from persisted transaction' {
    Check ((DemoContainerToken '6' $null) -eq 'preflight-b6') 'Validate has no safe interpolation token'
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c
    Check ((DemoContainerToken '6' (DemoLoadRegistry).transaction) -eq $c.token) 'Smoke lost Deploy ownership token'
    Reject {DemoContainerToken '7' (DemoLoadRegistry).transaction} 'token owner'
}
Case 'Incomplete candidate identity after interrupted prepare is fail-closed' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;DemoBeginTransaction $r $c '6';$r.transaction.candidate.Remove('containers')
    Reject {DemoRollback $r} 'Incomplete candidate identity';Check (!$script:events.Count) 'Guessed ownership after interruption'
}
Case 'Explicit recovery can retire interrupted preparation without touching stopped resources' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;DemoBeginTransaction $r $c '6';$r.transaction.candidate.Remove('containers');DemoSaveRegistry $r
    $result=DemoRecoverBuild (DemoLoadRegistry) '6' -Explicit
    Check ($result.status -eq 'PREPARATION_ABANDONED' -and $result.retainedContainerCount -eq 3 -and !(DemoLoadRegistry).transaction) 'Incomplete preparation not safely retired'
    Check (!$script:events.Count) 'Explicit retirement mutated containers'
}
Case 'Explicit incomplete preparation recovery cannot infer ownership to stop a running candidate' {
    $old=Fixture 5 -Running;$c=Fixture 6;$pgId=$c.containers.postgres.id;$r=Registry $old;DemoBeginTransaction $r $c '6';$r.transaction.candidate.Remove('containers')
    $script:containers[$pgId].State.Status='running'
    Reject {DemoRecoverBuild $r '6' -Explicit} 'Partial candidate is running';Check (!$script:events.Count) 'Unjournaled ID mutated'
}
Case 'Successful smoke promotes candidate atomically and retains previous manifest' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c;DemoCutover $r;StartCandidate $r
    DemoPromote $r @{exitCode=0;protectedUnchanged=$true};$saved=DemoLoadRegistry
    Check ($saved.active.project -eq $c.project -and !$saved.transaction -and $saved.history[0].previous.project -eq $old.project) 'Promotion history incomplete'
}
Case 'Other CI release/protected environment changes prevent cutover' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c;$script:otherCi='changed'
    Reject {DemoCutover $r} 'Protected environment changed';Check (!$script:events.Count) 'Mutation after protected change'
}
Case 'Exclusive registry lock rejects simultaneous deployment processes' {
    $one=DemoOpenRegistry;try{Reject {$two=DemoOpenRegistry;$two.Dispose()} 'used by another process|being used|cannot access'}finally{$one.Dispose()}
}
Case 'Never-started Docker endpoints may be empty but must match after start' {
    $c=Fixture 6;foreach($m in $script:containers.Values){foreach($n in $m.NetworkSettings.Networks.Values){$n.NetworkID=''}}
    DemoAssertRelease $c;$script:containers[$c.containers.backend.id].State.Status='running'
    Reject {DemoAssertRelease $c} 'endpoint identity mismatch'
}
Case 'Registry active/transaction identity disagreement is rejected' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c;$r.active=$c;DemoSaveRegistry $r
    Reject {DemoLoadRegistry} 'disagree'
}
Case 'Failed rollback cannot be automatically retried by post action' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c;DemoCutover $r
    $r.transaction.phase='RollbackFailed';DemoSaveRegistry $r;$before=$script:events.Count
    Reject {DemoRecoverBuild $r '6'} 'no automatic retry';Check ($script:events.Count -eq $before) 'Failed rollback retried'
}
Case 'Recovery callback cannot mutate another builds transaction' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c
    Reject {DemoRecoverBuild $r '7'} 'another build';Check (!$script:events.Count) 'Wrong-build recovery mutated runtime'
}
Case 'No previous release rollback verifies empty staging without inventing an active release' {
    $c=Fixture 6;$r=Registry $null;Prepare $r $c;DemoCutover $r;StartCandidate $r
    $result=DemoRollback $r;Check ($result.status -eq 'ROLLED_BACK' -and !$r.active -and $result.verification.emptyStagingVerified) 'First-release rollback wrong'
}
Case 'Prepared rollback before cutover accepts healthy previous backend without restart' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c
    $proof=DemoRecoverBuild (DemoLoadRegistry) '6' -Explicit
    Check ($proof.status -eq 'ROLLED_BACK' -and !(DemoLoadRegistry).transaction) 'Prepared recovery not completed'
    Check (!$script:events.Count) 'Prepared rollback restarted healthy previous services'
}
Case 'StoppingPrevious journal before first stop rolls back without restarting previous services' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c
    $r.transaction.phase='StoppingPrevious';$r.transaction.cutover=$true;DemoSaveRegistry $r
    $proof=DemoRecoverBuild (DemoLoadRegistry) '6'
    Check ($proof.status -eq 'ROLLED_BACK') 'Pre-stop interrupted cutover not recovered'
    Check (!$script:events.Count) 'Healthy previous release restarted after pre-stop interruption'
}
Case 'Explicit rollback retry accepts previous backend already running after failed HTTP verification' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c;DemoCutover $r;StartCandidate $r
    $script:httpFails=$true;Reject {DemoRollback $r} 'Rollback not verified';$script:httpFails=$false
    $count=$script:events.Count;$proof=DemoRecoverBuild (DemoLoadRegistry) '6' -Explicit
    Check ($proof.status -eq 'ROLLED_BACK' -and $script:events.Count -eq $count) 'Explicit retry restarted already healthy previous release'
}
Case 'Rollback refuses an unrelated Docker port owner before any container mutation' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c;$foreign=Fixture 7 -Running
    Reject {DemoRollback $r} 'Rollback not verified';Check (!$script:events.Count) 'Mutated containers despite unrelated Docker owner'
    Check ($r.transaction.phase -eq 'RollbackFailed') 'Unknown owner did not remain blocking'
}
Case 'Rollback refuses an unrelated host port owner with previous backend stopped' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c;DemoCutover $r
    $count=$script:events.Count;$script:unknownPort=$true
    Reject {DemoRollback $r} 'Rollback not verified';Check ($script:events.Count -eq $count) 'Mutated containers despite unknown host port'
}
Case 'RestoreActiveDeployment requires explicit confirmation' {
    $old=Fixture 5;$r=Registry $old
    Reject {DemoRestoreActiveDeployment $r} 'explicit confirmation';Check (!$script:events.Count) 'Unconfirmed restore mutated runtime'
}
Case 'RestoreActiveDeployment refuses an unresolved transaction' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c
    Reject {DemoRestoreActiveDeployment $r -Confirmed} 'Unresolved transaction';Check (!$script:events.Count) 'Restore bypassed pending transaction'
}
Case 'RestoreActiveDeployment starts exact stopped active IDs in dependency order after reboot' {
    $old=Fixture 5;foreach($m in $script:containers.Values){$m.State.Status='exited'};$r=Registry $old;DemoSaveRegistry $r
    $proof=DemoRestoreActiveDeployment (DemoLoadRegistry) -Confirmed
    Check ($proof.status -eq 'ACTIVE_DEPLOYMENT_VERIFIED' -and $proof.verification.image -eq $old.image -and $proof.protectedUnchanged) 'Restoration identity/health not verified'
    Check (($script:events -join '|') -eq ('start:'+$old.project+':postgres|start:'+$old.project+':osrm|start:'+$old.project+':backend')) 'Restore started wrong IDs or dependency order'
    Check (($proof.verification.startedServices -join '|') -eq 'postgres|osrm|backend') 'Started services evidence wrong'
}
Case 'RestoreActiveDeployment of a healthy release is a no-op in mocks' {
    $old=Fixture 5 -Running;$r=Registry $old;$before=DemoJsonHash $r
    $proof=DemoRestoreActiveDeployment $r -Confirmed
    Check (!$script:events.Count -and !$proof.verification.startedServices.Count) 'Healthy release restarted'
    Check ((DemoJsonHash $r) -eq $before) 'Restore changed release metadata'
}
Case 'RestoreActiveDeployment starts only missing services when PostgreSQL is already healthy' {
    $old=Fixture 5;$script:containers[$old.containers.postgres.id].State.Status='running';$r=Registry $old
    $proof=DemoRestoreActiveDeployment $r -Confirmed
    Check (($script:events -join '|') -eq ('start:'+$old.project+':osrm|start:'+$old.project+':backend')) 'Already healthy PostgreSQL restarted'
}
Case 'RestoreActiveDeployment rejects unknown Docker owner before starting anything' {
    $old=Fixture 5;$foreign=Fixture 7 -Running
    Reject {DemoRestoreActiveDeployment (Registry $old) -Confirmed} 'unknown container';Check (!$script:events.Count) 'Restore touched unknown Docker owner'
}
Case 'RestoreActiveDeployment rejects unknown host port owner before starting anything' {
    $old=Fixture 5;$script:unknownPort=$true
    Reject {DemoRestoreActiveDeployment (Registry $old) -Confirmed} 'Unknown host process';Check (!$script:events.Count) 'Restore bypassed host owner'
}
Case 'RestoreActiveDeployment rejects altered identity or unsupported active states' {
    $old=Fixture 5;$r=Registry $old;$script:containers[$old.containers.backend.id].Config.Labels['com.docker.compose.service']='postgres'
    Reject {DemoRestoreActiveDeployment $r -Confirmed} 'project/service/identity';Check (!$script:events.Count) 'Restore bypassed identity guard'
    $script:containers[$old.containers.backend.id].Config.Labels['com.docker.compose.service']='backend'
    $script:containers[$old.containers.postgres.id].State.Status='paused'
    Reject {DemoRestoreActiveDeployment $r -Confirmed} 'Unexpected active container state';Check (!$script:events.Count) 'Restore started paused/unknown state'
}
Case 'RestoreActiveDeployment start failure is not reported as healthy restoration' {
    $old=Fixture 5;$script:failStart=$old.containers.postgres.id
    Reject {DemoRestoreActiveDeployment (Registry $old) -Confirmed} 'Mock start failure'
    Check ($script:events.Count -eq 1 -and $script:containers[$old.containers.backend.id].State.Status -eq 'created') 'Started dependent services after failure'
}
Case 'RestoreActiveDeployment HTTP failure stays failed and retry does not restart running services' {
    $old=Fixture 5;$r=Registry $old;$script:httpFails=$true
    Reject {DemoRestoreActiveDeployment $r -Confirmed} 'Mock HTTP health failure'
    $count=$script:events.Count;$script:httpFails=$false;$proof=DemoRestoreActiveDeployment $r -Confirmed
    Check ($proof.status -eq 'ACTIVE_DEPLOYMENT_VERIFIED' -and $script:events.Count -eq $count) 'Retry restarted running services'
}
Case 'RestoreActiveDeployment cannot claim success after protected environment changed' {
    $old=Fixture 5;$script:changeProtectedOnStart=$true
    Reject {DemoRestoreActiveDeployment (Registry $old) -Confirmed} 'Protected environment changed'
    Check (@($script:events|Where-Object{$_ -notlike ('start:'+$old.project+':*')}).Count -eq 0) 'Restore mutated unrelated environment'
}
Case 'Promotion publication failure keeps pending transaction and previous active in memory and on disk' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c;DemoCutover $r;StartCandidate $r
    $before=DemoJsonHash $r;$script:failTerminalPublication=$true
    Reject {DemoPromote $r @{exitCode=0;protectedUnchanged=$true}} 'Mock durable registry publication failure'
    Check ((DemoJsonHash $r) -eq $before -and $r.transaction.phase -eq 'AwaitingSmoke' -and $r.active.project -eq $old.project) 'Promotion lost pending in-memory state'
    Check ((DemoLoadRegistry).transaction.phase -eq 'AwaitingSmoke') 'Promotion lost durable pending state'
    $script:failTerminalPublication=$false;DemoRollback $r|Out-Null;Check (!$r.transaction -and $r.active.project -eq $old.project) 'Failed promotion could not roll back'
}
Case 'Rollback completion write failure retains pending transaction and leaves history uncommitted' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c;DemoCutover $r;StartCandidate $r
    $script:failTerminalPublication=$true;Reject {DemoRollback $r} 'Rollback not verified'
    Check ($r.transaction.phase -eq 'RollbackFailed' -and $r.active.project -eq $old.project -and !$r.history.Count) 'Rollback cleared transaction or committed false history'
    Check ((DemoLoadRegistry).transaction.phase -eq 'RollbackFailed') 'Rollback write failure not durable'
    $count=$script:events.Count;$script:failTerminalPublication=$false;DemoRecoverBuild $r '6' -Explicit|Out-Null
    Check (!$r.transaction -and $script:events.Count -eq $count) 'Metadata retry restarted healthy services'
}
Case 'Persistent registry write failure never loses rollback recovery state in memory' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;Prepare $r $c;DemoCutover $r;StartCandidate $r
    $count=$script:events.Count;$script:failAllRegistryWrites=$true
    Reject {DemoRollback $r} 'Mock durable registry publication failure'
    Check ($r.transaction.phase -eq 'RollbackFailed' -and $r.active.project -eq $old.project -and !$r.history.Count) 'Persistent write failure lost recovery state'
    Check ((DemoLoadRegistry).transaction.phase -eq 'AwaitingSmoke') 'Last durable pending checkpoint changed'
    Check ($script:events.Count -eq $count) 'Runtime mutated after initial journal write failure'
}
Case 'Interrupted preparation publication failure preserves pending state for explicit retry' {
    $old=Fixture 5 -Running;$c=Fixture 6;$r=Registry $old;DemoBeginTransaction $r $c '6';$r.transaction.candidate.Remove('containers');DemoSaveRegistry $r
    $before=DemoJsonHash $r;$script:failTerminalPublication=$true
    Reject {DemoRecoverBuild $r '6' -Explicit} 'Mock durable registry publication failure'
    Check ((DemoJsonHash $r) -eq $before -and (DemoLoadRegistry).transaction.phase -eq 'Preparing') 'Preparation abandonment lost pending state'
    Check (!$script:events.Count) 'Preparation publication failure mutated runtime'
}
Write-Host ("Lifecycle regression: tests={0}; passed={1}; failed={2}; realDockerCalls=0; evidence={3}" -f ($script:passed+$script:failed),$script:passed,$script:failed,$testRoot)
if($script:failed){exit 1};exit 0
