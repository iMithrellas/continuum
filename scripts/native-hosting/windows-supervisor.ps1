param(
    [ValidateSet('start','stop','force','cleanup')][string]$Command,
    [string]$Runtime, [string]$Cli, [string]$Module, [string]$ListenAddress = '127.0.0.1:3001', [string]$Database,
    [string]$Data, [string]$ConfigDir, [string]$Lock, [string]$Log, [string]$Manifest, [string]$ModuleSha256, [string]$StartupNonce,
    [int]$SupervisorPid, [string]$SupervisorCreationTime, [string]$ManifestSha256
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -Path (Join-Path $PSScriptRoot 'WindowsNativeProcessControl.cs')
function Fail([string]$message, [int]$code = 64) { [Console]::Error.WriteLine($message); exit $code }
function Safe([string]$value) { return $value -and $value.IndexOfAny([char[]]"`r`n").Equals(-1) -and $value.IndexOf('"') -lt 0 }
function AtomicJson($value) { $tmp = "$Manifest.tmp.$PID"; [IO.File]::WriteAllText($tmp, ($value | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false)); Move-Item -LiteralPath $tmp -Destination $Manifest -Force }
function Liveness([int]$ProcessId) { if ($ProcessId -le 1) { return 'Dead' }; return [WindowsNativeProcessControl]::LivenessForPid([uint32]$ProcessId).ToString() }
function WaitDead([int]$ProcessId, [int]$milliseconds = 5000) {
    $until = [DateTime]::UtcNow.AddMilliseconds($milliseconds)
    do { $state = Liveness $ProcessId; if ($state -eq 'Dead') { return $true }; if ($state -eq 'Error') { return $false }; Start-Sleep -Milliseconds 100 } while ([DateTime]::UtcNow -lt $until)
    return $false
}
function ReadManifest { if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { return $null }; return Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json }
function CompletePublish($processLease, [string]$pinPath, [string]$digest) {
    if ($processLease.Liveness -ne 'Dead') { Fail 'CLI completion is not confirmed' 125 }
    if ($processLease.ExitCode -ne 0) { Fail "module publish failed with exit code $($processLease.ExitCode)" 125 }
    [IO.File]::WriteAllText($pinPath, $digest.ToLowerInvariant(), [Text.UTF8Encoding]::new($false))
    $processLease.Dispose()
}
function RequestMatches($r, $state, [string]$created) { return $r.pid -eq $PID -and $r.started_at -eq $created -and $r.startup_nonce -eq $state.startup_nonce }
function ProcessRequest($request, $state, $lease, $cliLease, [string]$created) {
    if (-not (Test-Path -LiteralPath $request -PathType Leaf)) { return $false }
    $r = Get-Content -LiteralPath $request -Raw | ConvertFrom-Json; Remove-Item -LiteralPath $request -Force
    if (-not (RequestMatches $r $state $created)) { return $false }
    if ($r.command -eq 'stop') {
        if ($state.stop_ticks -eq 0) { $state.stop_ticks = [Diagnostics.Stopwatch]::GetTimestamp(); $state.phase = 'stopping'; AtomicJson $state }
        if ($lease -and $lease.Liveness -eq 'Alive') { $lease.SendCtrlC() | Out-Null }
        return $true
    }
    if ($r.command -eq 'force') {
        $elapsed = ([Diagnostics.Stopwatch]::GetTimestamp() - $state.stop_ticks) / [double][Diagnostics.Stopwatch]::Frequency
        if ($state.stop_ticks -le 0 -or $elapsed -lt 5 -or $r.confirm_force -ne $true) { return $false }
        if ($cliLease -and $cliLease.Liveness -eq 'Alive') { $cliLease.ForceTerminate() | Out-Null }
        if ($lease -and $lease.Liveness -eq 'Alive') { $lease.ForceTerminate() | Out-Null }
        return $true
    }
    return $false
}

if ($Command -eq 'stop' -or $Command -eq 'force') {
    $state = ReadManifest
    if ($SupervisorPid -le 1 -or $null -eq $state) { Fail 'invalid supervisor identity' }
    $actual = try { [WindowsNativeProcessControl]::CreationTokenForPid([uint32]$SupervisorPid) } catch { '' }
    if ([int]$state.pid -ne $SupervisorPid -or $state.started_at -ne $SupervisorCreationTime -or $actual -ne $SupervisorCreationTime -or $state.startup_nonce -notmatch '^[A-Za-z0-9._-]+$') { Fail 'supervisor identity mismatch' 73 }
    $request = "$Manifest.$($state.startup_nonce).request"
    $payload = @{ command = $Command; confirm_force = ($Command -eq 'force'); pid = $SupervisorPid; started_at = $SupervisorCreationTime; startup_nonce = $state.startup_nonce }
    [IO.File]::WriteAllText("$request.tmp", ($payload | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath "$request.tmp" -Destination $request -Force
    exit 0
}

if ($Command -eq 'cleanup') {
    $state = ReadManifest
    if ($null -eq $state) {
        $finalData = [WindowsNativeProcessControl]::ResolveFinalPath($Data)
        if ([string]::IsNullOrEmpty($finalData)) { Fail 'could not resolve data ownership' 73 }
        $absentLock = [IO.FileStream]::new((Join-Path $finalData '.continuum-native.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { if (Test-Path -LiteralPath $Manifest) { Fail 'a new owner published metadata' 73 } } finally { $absentLock.Dispose() }
        exit 0
    }
    if ((Get-FileHash -LiteralPath $Manifest -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ManifestSha256.ToLowerInvariant()) { Fail 'manifest snapshot mismatch' 73 }
    if ((Liveness ([int]$state.pid)) -ne 'Dead' -or (Liveness ([int]$state.runtime_pid)) -ne 'Dead') { Fail 'owned process absence was not confirmed' 73 }
    $canonicalData = [WindowsNativeProcessControl]::ResolveFinalPath([string]$state.data_dir)
    if ([string]::IsNullOrEmpty($canonicalData)) { Fail 'could not resolve the final data directory' 73 }
    $canonicalData = $canonicalData.TrimEnd('\','/')
    $actualLock = Join-Path $canonicalData '.continuum-native.lock'
    New-Item -ItemType Directory -Force -Path $canonicalData | Out-Null
    $ownerLock = [IO.FileStream]::new($actualLock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        if ((Get-FileHash -LiteralPath $Manifest -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ManifestSha256.ToLowerInvariant() -or (Liveness ([int]$state.pid)) -ne 'Dead' -or (Liveness ([int]$state.runtime_pid)) -ne 'Dead') { Fail 'manifest changed or process absence became unknown' 73 }
        Remove-Item -LiteralPath $Manifest -Force
    } finally { $ownerLock.Dispose() }
    exit 0
}

if (-not $Runtime -or -not $Cli -or -not $Module -or -not $ConfigDir -or $ListenAddress -ne '127.0.0.1:3001' -or $Database -notmatch '^[A-Za-z0-9_-]+$' -or $ModuleSha256 -notmatch '^[0-9a-fA-F]{64}$' -or $StartupNonce -notmatch '^[A-Za-z0-9._-]+$') { Fail 'invalid native-hosting arguments' }
foreach ($v in @($Runtime,$Cli,$Module,$Data,$ConfigDir,$Lock,$Log,$Manifest)) { if (-not (Safe $v)) { Fail 'unsafe path argument' } }
foreach ($d in @($Data,$ConfigDir,(Split-Path $Manifest -Parent),(Split-Path $Log -Parent))) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$canonicalData = [WindowsNativeProcessControl]::ResolveFinalPath($Data)
if ([string]::IsNullOrEmpty($canonicalData)) { Fail 'could not resolve the final data directory' 73 }
$canonicalData = $canonicalData.TrimEnd('\','/')
$configDir = [IO.Path]::GetFullPath($ConfigDir).TrimEnd('\','/')
$configFile = Join-Path $configDir 'cli.toml'
if (-not (Test-Path -LiteralPath $configFile)) { [IO.File]::WriteAllText($configFile, '', [Text.UTF8Encoding]::new($false)) }
if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) { Fail 'isolated CLI config path is not a file' 66 }
$actualLock = Join-Path $canonicalData '.continuum-native.lock'
$ownerLock = [IO.FileStream]::new($actualLock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutexName = 'Global\Continuum.Native.2.10.0.' + $sid + '.' + ([Convert]::ToBase64String(([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($canonicalData.ToLowerInvariant())))).TrimEnd('=').Replace('/','_').Replace('+','-'))
$created = $false; $mutex = New-Object Threading.Mutex($false, $mutexName, [ref]$created)
try { $mutexOwned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mutexOwned = $true }
if (-not $mutexOwned) { $mutex.Dispose(); $ownerLock.Dispose(); Fail 'native server lock is already held' 73 }
$lease = $null; $cliLease = $null; $state = $null; $request = "$Manifest.$StartupNonce.request"; $createdAt = ''; $cleanupFailed = $false
try {
    if (-not (Test-Path -LiteralPath $Runtime -PathType Leaf) -or -not (Test-Path -LiteralPath $Cli -PathType Leaf) -or -not (Test-Path -LiteralPath $Module -PathType Leaf)) { Fail 'native distribution is incomplete' 127 }
    $runtimeHash = (Get-FileHash -LiteralPath $Runtime -Algorithm SHA256).Hash.ToLowerInvariant(); $cliHash = (Get-FileHash -LiteralPath $Cli -Algorithm SHA256).Hash.ToLowerInvariant(); $supervisorHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $distributionManifest = Join-Path (Split-Path -LiteralPath $Runtime -Parent) 'distribution-manifest.json'
    if (-not (Test-Path -LiteralPath $distributionManifest -PathType Leaf)) { Fail 'verified distribution manifest is missing' 66 }
    $distribution = Get-Content -LiteralPath $distributionManifest -Raw | ConvertFrom-Json
    if ($distribution.runtime -ne '2.10.0' -or $distribution.target -ne 'x86_64-pc-windows-msvc' -or $distribution.runtime_sha256.ToLowerInvariant() -ne $runtimeHash -or $distribution.cli_sha256.ToLowerInvariant() -ne $cliHash) { Fail 'runtime or CLI does not match the pinned distribution manifest' 66 }
    if ((Get-FileHash -LiteralPath $Module -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ModuleSha256.ToLowerInvariant()) { Fail 'module checksum mismatch' 65 }
    $pin = Join-Path $canonicalData '.continuum-module.sha256'; $phase = 'provisioning'
    if (Test-Path -LiteralPath $pin) { if ((Get-Content -LiteralPath $pin -Raw).Trim().ToLowerInvariant() -ne $ModuleSha256.ToLowerInvariant()) { Fail 'module digest differs; explicit upgrade is required' 66 }; $phase = 'starting' }
    [WindowsNativeProcessControl]::PrepareDedicatedConsole()
    $createdAt = [WindowsNativeProcessControl]::CreationTokenForPid([uint32]$PID)
    AtomicJson @{ phase = $phase; stop_ticks = 0; runtime = '2.10.0'; runtime_sha256 = $runtimeHash; cli_sha256 = $cliHash; supervisor_sha256 = $supervisorHash; module_sha256 = $ModuleSha256.ToLowerInvariant(); database = $Database; pid = $PID; started_at = $createdAt; runtime_pid = -1; runtime_started_at = ''; runtime_parent_pid = -1; runtime_binary = $Runtime; supervisor_binary = $PSCommandPath; startup_nonce = $StartupNonce; data_dir = $canonicalData; host = "http://$ListenAddress" }
    $state = ReadManifest
    $lease = [WindowsNativeProcessControl]::Start($Runtime, @('start','--listen-addr',$ListenAddress,'--data-dir',$canonicalData,'--jwt-key-dir',(Join-Path $configDir 'jwt')), $canonicalData, $Log)
    $state.runtime_pid = $lease.Pid; $state.runtime_started_at = $lease.CreationToken; $state.runtime_parent_pid = [WindowsNativeProcessControl]::ParentPidForPid($lease.Pid); AtomicJson $state
    $deadline = [DateTime]::UtcNow.AddSeconds(120); $healthy = $false
    while (-not $healthy -and [DateTime]::UtcNow -lt $deadline) { if (ProcessRequest $request $state $lease $null $createdAt) { Fail 'stop requested during runtime startup' 125 }; try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 -Uri "http://$ListenAddress/v1/ping" | Out-Null; $healthy = $true } catch { if ($lease.Liveness -eq 'Dead') { Fail 'runtime exited before health check' 125 }; if ($lease.Liveness -eq 'Error') { Fail 'runtime liveness is unknown' 125 }; Start-Sleep -Milliseconds 250 } }
    if (-not $healthy) { Fail 'runtime did not become healthy before deadline' 124 }
    if ($phase -eq 'provisioning') {
        $cliLog = "$Log.cli"; $cliErr = "$Log.cli.err"; $cliLease = [WindowsNativeProcessControl]::Start($Cli, @('--config-path',$configFile,'publish','--server',"http://$ListenAddress",'--yes','-b',$Module,$Database), $canonicalData, $cliLog)
        while ($cliLease.Liveness -eq 'Alive') { if (ProcessRequest $request $state $lease $cliLease $createdAt) { Fail 'stop requested during module provisioning' 125 }; Start-Sleep -Milliseconds 100 }
        CompletePublish $cliLease $pin $ModuleSha256
        $cliLease = $null
    }
    $state.phase = 'running'; AtomicJson $state
    while ($lease.Liveness -eq 'Alive') {
        ProcessRequest $request $state $lease $cliLease $createdAt | Out-Null
        if ($state.stop_ticks -gt 0 -and ([Diagnostics.Stopwatch]::GetTimestamp() - $state.stop_ticks) / [double][Diagnostics.Stopwatch]::Frequency -ge 5 -and $state.phase -ne 'stop_timeout') { $state.phase = 'stop_timeout'; AtomicJson $state }
        Start-Sleep -Milliseconds 200
    }
    if ($lease.Liveness -eq 'Error') { Fail 'runtime liveness is unknown' 125 }
} finally {
    # Never release the data lock or kill a running game merely because setup or
    # graceful shutdown timed out. Keep servicing the explicit force request.
    if ($state -and (($lease -and $lease.Liveness -ne 'Dead') -or ($cliLease -and $cliLease.Liveness -ne 'Dead'))) {
        if ($state.stop_ticks -eq 0) { $state.stop_ticks = [Diagnostics.Stopwatch]::GetTimestamp() }
        $state.phase = 'stopping'; AtomicJson $state
        if ($lease -and $lease.Liveness -eq 'Alive') { $lease.SendCtrlC() | Out-Null }
        elseif ($cliLease -and $cliLease.Liveness -eq 'Alive') { $cliLease.SendCtrlC() | Out-Null }
        while (($lease -and $lease.Liveness -ne 'Dead') -or ($cliLease -and $cliLease.Liveness -ne 'Dead')) {
            if (([Diagnostics.Stopwatch]::GetTimestamp() - $state.stop_ticks) / [double][Diagnostics.Stopwatch]::Frequency -ge 5 -and $state.phase -ne 'stop_timeout') { $state.phase = 'stop_timeout'; AtomicJson $state }
            ProcessRequest $request $state $lease $cliLease $createdAt | Out-Null
            Start-Sleep -Milliseconds 200
        }
    }
    if ($cliLease) { $cliLease.Dispose(); $cliLease = $null }
    if ($lease) { $lease.Dispose(); $lease = $null }
    while (-not [WindowsNativeProcessControl]::CleanupRetainedFailure()) { Start-Sleep -Milliseconds 200 }
    $current = ReadManifest
    if ($current -and [int]$current.pid -eq $PID -and $current.started_at -eq $createdAt -and $current.startup_nonce -eq $StartupNonce) {
        if ([int]$current.runtime_pid -gt 1) { $current.phase = 'stopped'; AtomicJson $current }
        else { Remove-Item -LiteralPath $Manifest -Force }
    }
    Remove-Item -LiteralPath $request -Force -ErrorAction SilentlyContinue; [WindowsNativeProcessControl]::ReleaseDedicatedConsole(); if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }; $ownerLock.Dispose()
}
