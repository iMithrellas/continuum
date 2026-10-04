$ErrorActionPreference = 'Stop'
function Assert([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Fail([string]$message, [int]$code = 64) { throw $message }
function AtomicJson($value) { $script:observedPhase = $value.phase }
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'windows-supervisor.ps1'), [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'supervisor script parses'
foreach ($name in @('CompletePublish','PublicationPhase','InstallModule','RequestMatches','ProcessRequest','IsLocalListenAddress')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
Assert (IsLocalListenAddress '127.0.0.1:3002') 'alternate local ports are accepted'
Assert (IsLocalListenAddress '127.0.0.1:65535') 'highest valid port is accepted'
foreach ($address in @('0.0.0.0:3002','127.0.0.1:03002','127.0.0.1:65536','127.0.0.1:80','127.0.0.1:3002/injected')) {
    Assert (-not (IsLocalListenAddress $address)) 'unsafe listener is rejected'
}
foreach ($parameter in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.ParameterAst] }, $true)) {
    Assert ($parameter.Name.VariablePath.UserPath -notin @('PID','Host')) 'automatic read-only variables are not parameters'
}
class MockNativeLease {
    [string]$Liveness = 'Alive'
    [uint32]$ExitCode = 0
    [int]$GraceCalls = 0
    [int]$ForceCalls = 0
    [bool]$Disposed = $false
    [bool] SendCtrlC() { $this.GraceCalls++; return $true }
    [bool] ForceTerminate() { $this.ForceCalls++; $this.Liveness = 'Dead'; return $true }
    [void] Dispose() { $this.Disposed = $true }
}
$directory = Join-Path ([IO.Path]::GetTempPath()) ('continuum-win-state-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    $pin = Join-Path $directory 'module.pin'
    $cli = [MockNativeLease]::new(); $cli.Liveness = 'Dead'; $cli.ExitCode = 7
    $rejected = $false
    try { CompletePublish $cli $pin ('a' * 64) } catch { $rejected = $true }
    Assert $rejected 'nonzero CLI status rejects publication'
    Assert (-not (Test-Path -LiteralPath $pin)) 'failed publish does not write a module pin'
    $cli.ExitCode = 0
    CompletePublish $cli $pin ('a' * 64)
    Assert ($cli.Disposed -and (Test-Path -LiteralPath $pin)) 'successful publication pins and disposes once'
    $cli = [MockNativeLease]::new(); $cli.Liveness = 'Dead'; $cli.ExitCode = 7
    try { CompletePublish $cli $pin ('b' * 64) } catch { }
    Assert ((Get-Content -LiteralPath $pin -Raw) -eq ('a' * 64)) 'failed update keeps the previously deployed pin'
    Assert ((PublicationPhase $pin ('a' * 64) $false) -eq 'starting') 'ordinary restart does not republish'
    Assert ((PublicationPhase $pin ('b' * 64) $true) -eq 'provisioning') 'explicit update publishes the changed module'
    $rejected = $false
    try { PublicationPhase $pin ('b' * 64) $false | Out-Null } catch { $rejected = $true }
    Assert $rejected 'implicit digest changes still require explicit update'
    $instance = Join-Path $directory 'profile'
    New-Item -ItemType Directory -Path (Join-Path $instance 'data') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $instance 'config') | Out-Null
    $save = Join-Path $instance 'data/colony.save'; [IO.File]::WriteAllText($save, 'persistent colony')
    $source = Join-Path $directory 'current.wasm'; [IO.File]::WriteAllText($source, 'current module')
    $digest = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    $profileModule = Join-Path $instance 'continuum_module.wasm'
    InstallModule $instance $source $digest
    Assert ((Get-Content -LiteralPath $profileModule -Raw) -eq 'current module') 'file-only helper installs the selected profile module'
    $rejected = $false
    try { InstallModule $instance $source ('b' * 64) } catch { $rejected = $true }
    Assert ($rejected -and (Get-Content -LiteralPath $profileModule -Raw) -eq 'current module') 'checksum failure preserves the old per-server artifact'
    $held = [IO.FileStream]::new((Join-Path $instance 'data/.continuum-native.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $rejected = $false
        try { InstallModule $instance $source $digest } catch { $rejected = $true }
        Assert $rejected 'held runtime data lock refuses module installation'
    } finally { $held.Dispose() }
    $manifest = Join-Path $instance 'server.json'; [IO.File]::WriteAllText($manifest, 'ambiguous owner')
    $rejected = $false
    try { InstallModule $instance $source $digest } catch { $rejected = $true }
    Assert ($rejected -and (Get-Content -LiteralPath $save -Raw) -eq 'persistent colony') 'ownership conflict refuses update without changing colony data'
    Assert ($ast.Extent.Text.Contains("'--delete-data=never'")) 'Windows publication must never reset colony data'
    $runtime = [MockNativeLease]::new()
    $state = @{startup_nonce='test'; stop_ticks=0; phase='running'}
    $request = Join-Path $directory 'request.json'
    $payload = @{command='force'; confirm_force=$true; pid=$PID; started_at='created'; startup_nonce='test'}
    $payload | ConvertTo-Json | Set-Content -LiteralPath $request
    Assert (-not (ProcessRequest $request $state $runtime $null 'created')) 'force without graceful timeout is rejected'
    Assert ($runtime.ForceCalls -eq 0) 'premature force never touches the process'
    $payload.command = 'stop'; $payload | ConvertTo-Json | Set-Content -LiteralPath $request
    Assert (ProcessRequest $request $state $runtime $null 'created') 'graceful request is accepted'
    Assert ($runtime.GraceCalls -eq 1 -and $state.phase -eq 'stopping') 'graceful phase is persisted'
    $state.stop_ticks = [Diagnostics.Stopwatch]::GetTimestamp() - 6 * [Diagnostics.Stopwatch]::Frequency
    $payload.command = 'force'; $payload | ConvertTo-Json | Set-Content -LiteralPath $request
    Assert (ProcessRequest $request $state $runtime $null 'created') 'confirmed force after timeout is accepted'
    Assert ($runtime.ForceCalls -eq 1) 'one owned force request is delivered'
    Write-Output 'WINDOWS_SUPERVISOR_STATE_PASS'
} finally { Remove-Item -LiteralPath $directory -Recurse -Force }
