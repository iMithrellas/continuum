$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'WindowsNativeProcessControl.cs')
function Assert([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
Assert ([WindowsNativeProcessControl]::Quote('C:\User Name\Data\') -eq '"C:\User Name\Data\\"') 'trailing backslashes must be doubled before the closing quote'
Assert ([WindowsNativeProcessControl]::Quote('plain') -eq '"plain"') 'plain argument quoting'
try { [WindowsNativeProcessControl]::Quote("line`n") | Out-Null; throw 'newline was accepted' } catch [ArgumentException] { }
Assert ([WindowsNativeProcessControl]::NormalizeCreationTime('132441192000000000') -eq '132441192000000000') 'creation tokens are invariant decimal FILETIME ticks'
Assert ([WindowsNativeProcessControl]::CanSendCtrlC($true, $true)) 'Ctrl+C is allowed for a live child in our dedicated console'
Assert (-not [WindowsNativeProcessControl]::CanSendCtrlC($false, $true)) 'Ctrl+C is blocked without our dedicated console'
Assert (-not [WindowsNativeProcessControl]::CanSendCtrlC($true, $false)) 'Ctrl+C is blocked after the held child handle reports exit'
$leaseFields = [WindowsNativeProcessLease].GetFields([Reflection.BindingFlags]'Instance,NonPublic')
Assert (($leaseFields | Where-Object { $_.FieldType.Name -eq 'SafeKernelHandle' }).Count -eq 2) 'leases retain typed safe process and job handles'
Assert ([WindowsNativeProcessControl]::CommandLine('C:\Program Files\Continuum\spacetime.exe', @('--config-path','C:\Users\test user\cli.toml')).Contains('"C:\Users\test user\cli.toml"')) 'CLI arguments use Windows CRT quoting for spaces and backslashes'
Assert ([WindowsNativeProcessControl]::StartFailureDisposition($false, $false, $false).ToString() -eq 'NoProcessCleanup') 'CreateProcess failure has no child cleanup obligation'
Assert ([WindowsNativeProcessControl]::StartFailureDisposition($true, $true, $false).ToString() -eq 'Cleaned') 'job setup failure is clean after confirmed child death'
Assert ([WindowsNativeProcessControl]::StartFailureDisposition($true, $false, $true).ToString() -eq 'RetainOwnedError') 'unknown child death retains owned failure state'
$shell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$supervisor = 'C:\Users\test user\native\windows-supervisor.ps1'
Assert ([WindowsNativeProcessControl]::MatchesProcessRole($shell, $supervisor, @($shell,'-NoProfile','-File',$supervisor,'start'), $shell)) 'a script supervisor is identified by its interpreter and exact File argument'
Assert (-not [WindowsNativeProcessControl]::MatchesProcessRole($shell, $supervisor, @($shell,'-File','C:\another.ps1'), $shell)) 'a different script is not our supervisor'
Assert ([WindowsNativeProcessControl]::MatchesProcessRole('C:\native\spacetimedb-standalone.exe','C:\native\spacetimedb-standalone.exe',@(),$shell)) 'runtime identity uses its executable'
Write-Output 'WINDOWS_PROCESS_CONTROL_QUOTE_PASS'
