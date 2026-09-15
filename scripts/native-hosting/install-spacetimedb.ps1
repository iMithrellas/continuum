param([string]$Destination = "$env:LOCALAPPDATA\Continuum\native\spacetimedb\2.10.0", [string]$HelperDestination = "$env:LOCALAPPDATA\Continuum\native\helpers")
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$url = "https://github.com/clockworklabs/SpacetimeDB/releases/download/v2.10.0/spacetime-x86_64-pc-windows-msvc.zip"
$sha256 = "ff7027140b25de58ad6dc2751545264d3926d2f79352ee6093084aa7ecf6737a"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("continuum-spacetime-2.10.0-{0}.zip" -f ([guid]::NewGuid().ToString("N")))
try {
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 300
    if ((Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha256) { throw "SpacetimeDB archive hash mismatch" }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Expand-Archive -LiteralPath $tmp -DestinationPath $Destination -Force
} finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
New-Item -ItemType Directory -Force -Path $helperDestination | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows-supervisor.ps1') -Destination (Join-Path $helperDestination 'windows-supervisor.ps1') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'WindowsNativeProcessControl.cs') -Destination (Join-Path $helperDestination 'WindowsNativeProcessControl.cs') -Force
$runtime = Join-Path $Destination "spacetimedb-standalone.exe"
$cli = Join-Path $Destination "spacetimedb-cli.exe"
if (-not (Test-Path -LiteralPath $runtime -PathType Leaf) -or -not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw "SpacetimeDB archive is missing the expected Windows executables" }
@{
    runtime = "2.10.0"
    target = "x86_64-pc-windows-msvc"
    archive_sha256 = $sha256
    runtime_sha256 = (Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash.ToLowerInvariant()
    cli_sha256 = (Get-FileHash -LiteralPath $cli -Algorithm SHA256).Hash.ToLowerInvariant()
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination "distribution-manifest.json") -Encoding UTF8
Write-Output "Installed and verified SpacetimeDB 2.10.0 at $Destination"
