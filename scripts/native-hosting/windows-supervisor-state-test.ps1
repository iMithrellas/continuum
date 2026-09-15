$ErrorActionPreference = 'Stop'
function Assert([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Fail([string]$message, [int]$code = 64) { throw $message }
function AtomicJson($value) { $script:observedPhase = $value.phase }
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'windows-supervisor.ps1'), [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'supervisor script parses'
foreach ($name in @('CompletePublish','RequestMatches','ProcessRequest')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
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
