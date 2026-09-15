param(
    [Parameter(Mandatory = $true)][string]$Runtime,
    [Parameter(Mandatory = $true)][string]$Cli,
    [Parameter(Mandatory = $true)][string]$Module,
    [Parameter(Mandatory = $true)][string]$Supervisor,
    [Parameter(Mandatory = $true)][string]$DataDirectory,
    [Parameter(Mandatory = $true)][string]$ConfigDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This integration gate must run on Windows.' }
foreach ($path in @($Runtime, $Cli, $Module, $Supervisor)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing required file: $path" } }
New-Item -ItemType Directory -Force -Path $DataDirectory, $ConfigDirectory | Out-Null
$manifest = Join-Path $DataDirectory 'server.json'; $log = Join-Path $DataDirectory 'server.log'; $config = Join-Path $ConfigDirectory 'cli.toml'
if (-not (Test-Path -LiteralPath $config)) { New-Item -ItemType File -Path $config | Out-Null }
$moduleHash = (Get-FileHash -LiteralPath $Module -Algorithm SHA256).Hash.ToLowerInvariant(); $nonce = [guid]::NewGuid().ToString('N')
$arguments = @('-NoProfile','-NonInteractive','-File',$Supervisor,'start','-Runtime',$Runtime,'-Cli',$Cli,'-Module',$Module,'-ListenAddress','127.0.0.1:3001','-Database','continuum','-Data',$DataDirectory,'-ConfigDir',$ConfigDirectory,'-Lock',(Join-Path $DataDirectory 'ignored-legacy-lock-name'),'-Log',$log,'-Manifest',$manifest,'-ModuleSha256',$moduleHash,'-StartupNonce',$nonce)
Add-Type -Path (Join-Path (Split-Path $Supervisor -Parent) 'WindowsNativeProcessControl.cs')
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = @('-ExecutionPolicy','Bypass') + $arguments
$encodedArguments = ($arguments | ForEach-Object { [WindowsNativeProcessControl]::Quote([string]$_) }) -join ' '
$supervisorProcess = Start-Process -FilePath $powershell -ArgumentList $encodedArguments -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(180); $state = $null
    while ([DateTime]::UtcNow -lt $deadline) { if (Test-Path -LiteralPath $manifest) { $state = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json; if ($state.phase -eq 'running') { break } }; if ($supervisorProcess.HasExited) { throw "Supervisor exited with code $($supervisorProcess.ExitCode)." }; Start-Sleep -Milliseconds 500 }
    if ($null -eq $state -or $state.phase -ne 'running') { throw 'Supervisor did not reach running phase.' }
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Uri 'http://127.0.0.1:3001/v1/ping' | Out-Null
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Supervisor stop -Manifest $manifest -SupervisorPid $state.pid -SupervisorCreationTime $state.started_at
    if ($LASTEXITCODE -ne 0) { throw 'Graceful stop request was rejected.' }
    $supervisorProcess.WaitForExit(15000) | Out-Null
    if (-not $supervisorProcess.HasExited) { throw 'Supervisor did not complete graceful shutdown.' }
    $snapshot = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Supervisor cleanup -Data $DataDirectory -Manifest $manifest -ManifestSha256 $snapshot
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $manifest)) { throw 'Confirmed-dead ownership metadata was not cleaned up.' }
    Write-Output 'WINDOWS_NATIVE_INTEGRATION_GATE_PASS'
} finally { if (-not $supervisorProcess.HasExited) { $supervisorProcess.Kill(); $supervisorProcess.WaitForExit() } }
