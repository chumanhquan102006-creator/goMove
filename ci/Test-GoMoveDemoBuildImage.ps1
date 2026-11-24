#requires -Version 7.2
# Executes the real BuildImage clause with mocked Docker. No application tests or live builds.
$ErrorActionPreference='Stop'
$helper=Join-Path $PSScriptRoot 'Invoke-GoMoveDemo.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Helper syntax invalid'}
$clauses=@(foreach($s in $ast.FindAll({param($n) $n -is [Management.Automation.Language.SwitchStatementAst]},$true)){
    $parent=$s.Parent;while($parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]){$parent=$parent.Parent}
    if($parent){continue} # Exclude the ResourceGate switch; exercise the top-level action.
    foreach($c in $s.Clauses){if($c.Item1.Value -eq 'BuildImage'){$c.Item2}}
})
if($clauses.Count -ne 1){throw 'Expected the unique real BuildImage action'}
$body=$clauses[0].Extent.Text
$script:buildAction=[scriptblock]::Create($body.Substring(1,$body.Length-2))
$root=Join-Path ([IO.Path]::GetTempPath()) ('gomove-buildimage-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$script:passed=0;$script:failed=0
$priorBuild=[Environment]::GetEnvironmentVariable('BUILD_NUMBER','Process')
function HashFile($Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function ResourceGate{$script:gateCalled=$true}
function Record($Name,$Data){$script:recorded=@{name=$Name;data=$Data}}
function Native([string]$File,[string[]]$Arguments,[switch]$Show){
    if($File -ne 'docker' -or !$script:gateCalled){throw 'Unexpected native call / resource gate bypass'}
    $script:calls.Add(@{file=$File;arguments=$Arguments})
    if(($Arguments[0..1] -join ' ') -eq 'image ls'){
        if($script:inventoryError){throw 'Mock Docker daemon unavailable'}
        if($script:badJson){return 'unparseable Docker output'}
        if($script:badSchema){return '{"error":"Unexpected Docker output"}'}
        if($script:cachePresent){return (@{Repository=$script:repository;Digest=$script:digest;ID=$script:digest}|ConvertTo-Json -Compress)}
        return ''
    }
    if($Arguments[0] -eq 'pull'){
        if($script:pullError){throw 'Mock registry DNS failure'}
        $script:cachePresent=$true;return 'Mock immutable pull completed'
    }
    if(($Arguments[0..1] -join ' ') -eq 'image inspect'){
        if($script:inspectError){throw 'Mock image inspection failed'}
        $repo=if($script:badDigest){'eclipse-temurin@sha256:'+('f'*64)}else{'eclipse-temurin@'+$script:digest}
        return (@{Id=$script:digest;Os=$script:os;Architecture=$script:architecture;RepoDigests=@($repo)}|ConvertTo-Json -Compress)
    }
    if($Arguments[0] -eq 'build'){
        $iid=$Arguments[[array]::IndexOf($Arguments,'--iidfile')+1]
        if(![IO.Path]::GetFullPath($iid).StartsWith([IO.Path]::GetFullPath($root)+[IO.Path]::DirectorySeparatorChar)){throw 'Mock output escaped test directory'}
        [IO.File]::WriteAllText($iid,('sha256:'+('a'*64)));return 'Mock build completed'
    }
    throw 'Unexpected Docker command'
}
function ResetCase{
    $script:Run=Join-Path $root ([guid]::NewGuid().ToString('N'));$script:Evidence=Join-Path $script:Run 'evidence'
    New-Item -ItemType Directory -Path $script:Evidence,(Join-Path $script:Run 'image-context/health')|Out-Null
    [IO.File]::WriteAllText((Join-Path $script:Run 'image-context/app.jar'),'isolated mock JAR')
    [IO.File]::Copy((Join-Path $PSScriptRoot 'Dockerfile.demo'),(Join-Path $script:Run 'image-context/Dockerfile'))
    [IO.File]::WriteAllText((Join-Path $script:Run 'image-context/.dockerignore'),'mock context')
    [IO.File]::WriteAllText((Join-Path $script:Run 'image-context/health/HealthProbe.class'),'mock class bytes')
    $script:DemoState=@{steps=@{BuildJar=@{data=@{sha256=(HashFile (Join-Path $script:Run 'image-context/app.jar'))}}}}
    $script:Revision='610c71d140867c89b0b3860ef3cf0141600631bd';$env:BUILD_NUMBER='6'
    $script:RepositoryUrl='https://github.com/chumanhquan102006-creator/goMove.git'
    $script:digest='sha256:0b99b3376fbb50dbf9c0af8535fdd5b8eb0d3fdfc8b1e4967f383b6919f6901a'
    $script:repository='eclipse-temurin';$script:os='linux';$script:architecture='amd64'
    $script:calls=[Collections.Generic.List[object]]::new();$script:cachePresent=$true;$script:recorded=$null;$script:gateCalled=$false
    $script:inventoryError=$false;$script:badJson=$false;$script:badSchema=$false;$script:inspectError=$false;$script:badDigest=$false;$script:pullError=$false
}
function InvokeAction{& $script:buildAction}
function Check($Condition,[string]$Message){if(!$Condition){throw $Message}}
function Reject([scriptblock]$Body,[string]$Pattern){try{& $Body;throw 'Expected rejection missing'}catch{if($_.Exception.Message -notmatch $Pattern){throw}}}
function CountCalls([string]$Operation){@($script:calls|Where-Object{$_.arguments[0] -eq $Operation}).Count}
function Case([string]$Name,[scriptblock]$Body){ResetCase;try{& $Body;$script:passed++;Write-Host ('PASS '+$Name)}catch{$script:failed++;Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}}
try{
    Case 'Cached exact immutable base skips pull and builds with unchanged security/provenance flags' {
        InvokeAction;Check ((CountCalls pull) -eq 0 -and (CountCalls build) -eq 1) 'Unnecessary pull or missing build'
        $build=@($script:calls|Where-Object{$_.arguments[0] -eq 'build'})[0].arguments
        Check (($build -contains '--pull=false') -and $build[[array]::IndexOf($build,'--network')+1] -eq 'none' -and $build[[array]::IndexOf($build,'--platform')+1] -eq 'linux/amd64') 'Build safety flags changed'
        Check ($build -contains ('org.opencontainers.image.revision='+$script:Revision) -and $build -contains ('gomove.jar.sha256='+$script:DemoState.steps.BuildJar.data.sha256)) 'Image provenance labels changed'
        Check ($script:recorded.name -eq 'BuildImage' -and $script:recorded.data.exitCode -eq 0) 'Real action result not recorded'
    }
    Case 'Successful empty inventory pulls exactly the pinned base once' {
        $script:cachePresent=$false;InvokeAction
        Check ((CountCalls pull) -eq 1 -and (CountCalls build) -eq 1) 'Absent base not fetched once'
        $pull=@($script:calls|Where-Object{$_.arguments[0] -eq 'pull'})[0].arguments
        Check ($pull[-1] -ceq ('eclipse-temurin:21-jre@'+$script:digest) -and $pull[2] -eq 'linux/amd64') 'Pull lost digest or platform'
    }
    Case 'Docker inventory error is not a cache miss' {
        $script:inventoryError=$true;Reject {InvokeAction} 'daemon unavailable';Check ((CountCalls pull) -eq 0 -and (CountCalls build) -eq 0) 'Inventory error triggered pull/build'
    }
    Case 'Malformed inventory JSON fails closed without pull' {
        $script:badJson=$true;Reject {InvokeAction} 'JSON|Unexpected character';Check ((CountCalls pull) -eq 0 -and (CountCalls build) -eq 0) 'Malformed inventory caused pull/build'
    }
    Case 'Unexpected inventory schema is not absence' {
        $script:badSchema=$true;Reject {InvokeAction} 'Invalid Docker image inventory';Check ((CountCalls pull) -eq 0) 'Unexpected output became a cache miss'
    }
    Case 'Cached inspection failure is not retried by pulling' {
        $script:inspectError=$true;Reject {InvokeAction} 'inspection failed';Check ((CountCalls pull) -eq 0 -and (CountCalls build) -eq 0) 'Inspect failure triggered pull/build'
    }
    Case 'Cached wrong architecture fails without pull or application build' {
        $script:architecture='arm64';Reject {InvokeAction} 'digest/platform mismatch';Check ((CountCalls pull) -eq 0 -and (CountCalls build) -eq 0) 'Wrong platform accepted'
    }
    Case 'Cached wrong OS fails without pull or application build' {
        $script:os='windows';Reject {InvokeAction} 'digest/platform mismatch';Check ((CountCalls pull) -eq 0 -and (CountCalls build) -eq 0) 'Wrong OS accepted'
    }
    Case 'Cached inspected digest mismatch blocks build' {
        $script:badDigest=$true;Reject {InvokeAction} 'digest/platform mismatch';Check ((CountCalls pull) -eq 0 -and (CountCalls build) -eq 0) 'Wrong inspected digest accepted'
    }
    Case 'Canonical Docker Hub repository alias is recognized locally' {
        $script:repository='docker.io/library/eclipse-temurin';InvokeAction;Check ((CountCalls pull) -eq 0 -and (CountCalls build) -eq 1) 'Canonical alias caused pull'
    }
    Case 'Other repository with same digest cannot substitute for required base ref' {
        $script:repository='unrelated/runtime';InvokeAction;Check ((CountCalls pull) -eq 1) 'Unrelated repository substituted for exact ref'
    }
    Case 'Absent base pull failure blocks dependent build' {
        $script:cachePresent=$false;$script:pullError=$true;Reject {InvokeAction} 'registry DNS failure';Check ((CountCalls pull) -eq 1 -and (CountCalls build) -eq 0) 'Pull failure ignored'
    }
    Case 'Missing newly built JAR still blocks all Docker work' {
        $script:DemoState.steps.Remove('BuildJar');Reject {InvokeAction} 'No newly built JAR';Check ($script:calls.Count -eq 0) 'JAR guard bypassed'
    }
    Case 'Modified context JAR still blocks all Docker work' {
        [IO.File]::AppendAllText((Join-Path $script:Run 'image-context/app.jar'),'changed');Reject {InvokeAction} 'Staged JAR changed';Check ($script:calls.Count -eq 0) 'JAR integrity bypassed'
    }
    Case 'Unexpected context file still blocks all Docker work' {
        [IO.File]::WriteAllText((Join-Path $script:Run 'image-context/unexpected.txt'),'not allowed');Reject {InvokeAction} 'Unexpected file';Check ($script:calls.Count -eq 0) 'Context whitelist bypassed'
    }
}finally{[Environment]::SetEnvironmentVariable('BUILD_NUMBER',$priorBuild,'Process')}
Write-Host ("BuildImage focused: tests={0}; passed={1}; failed={2}; realDockerCalls=0" -f ($script:passed+$script:failed),$script:passed,$script:failed)
if($script:failed){exit 1};exit 0
