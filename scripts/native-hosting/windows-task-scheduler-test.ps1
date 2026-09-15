$ErrorActionPreference = 'Stop'
function Assert([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
$adapter = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\client\godot\scripts\native_server_windows_adapter.gd')
Assert ($adapter.Contains('$f.RegisterTask($args[1],$raw,6')) 'Task Scheduler uses raw XML RegisterTask, not RegisterTaskDefinition with an XML node'
Assert ($adapter.Contains('$f.GetTask($args[1])')) 'Task Scheduler readback is name based'
Assert ($adapter.Contains('-2147024894')) 'missing tasks are recognized by COM HRESULT, not localized text'
Assert ($adapter.Contains('$a.Arguments -ne [string]$d.Task.Actions.Exec.Arguments')) 'readback compares exact task arguments'
Assert ($adapter.Contains('$actual.Principal.LogonType -ne 3')) 'readback checks an interactive user token'
Assert ($adapter.Contains('$trigger.Type -ne 9') -and $adapter.Contains('$trigger.UserId -ne $sid')) 'readback checks the matching user logon trigger'
Assert (-not $adapter.Contains('$t.Definition.Xml;')) 'readback uses actual COM definition properties, not a nonexistent Xml property'
Assert ($adapter.Contains("RegistrationInfo.Source -ne 'Continuum native'") -and $adapter.Contains('RegistrationInfo.URI -ne $args[6]')) 'existing task ownership is validated before mutation'
Assert ($adapter.IndexOf('$old.RegistrationInfo.Source') -lt $adapter.IndexOf('$f.DeleteTask')) 'ownership check precedes deletion'
Assert ($adapter.Contains('ConfigDir')) 'the task passes the manager config directory'
Write-Output 'WINDOWS_TASK_SCHEDULER_SOURCE_CONTRACT_PASS'
