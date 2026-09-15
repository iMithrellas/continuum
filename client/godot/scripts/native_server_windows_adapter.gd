class_name ContinuumNativeServerWindowsAdapter extends RefCounted

const TASK_NAME := "Continuum Native SpacetimeDB"

func _architecture() -> String:
	var wow := OS.get_environment("PROCESSOR_ARCHITEW6432")
	return wow if not wow.is_empty() else OS.get_environment("PROCESSOR_ARCHITECTURE")

func supports_native_hosting() -> bool:
	return OS.get_name() == "Windows" and ["x86_64", "AMD64"].has(_architecture())

func capability_report() -> Dictionary:
	return {"supported": supports_native_hosting(), "platform": OS.get_name(), "architecture": _architecture(), "runtime": "SpacetimeDB 2.10.0 x86_64-pc-windows-msvc", "verified_here": false, "warning": "Windows lifecycle, Ctrl+C, Job Object, and Task Scheduler validation require a Windows release check."}

func runtime_path(install_dir: String) -> String:
	return install_dir.path_join("spacetimedb-standalone.exe")

func cli_path(install_dir: String) -> String:
	return install_dir.path_join("spacetimedb-cli.exe")

func same_data_path(actual: String, configured: String) -> bool:
	var output: Array = []
	var script := "& { $ErrorActionPreference='Stop'; Add-Type -Path $args[1]; [WindowsNativeProcessControl]::ResolveFinalPath($args[0]) }"
	if OS.execute(_powershell_path(), ["-NoProfile", "-NonInteractive", "-Command", script, configured, _helper_path()], output, true) != 0 or output.is_empty():
		return false
	return actual.replace("\\", "/").to_lower() == str(output[0]).strip_edges().replace("\\", "/").to_lower()

func supports_runtime_adoption() -> bool:
	return false # A supervisor exit closes its Job Object and terminates the runtime.

func install_runtime(script: String, destination: String, helpers: String, output: Array) -> int:
	return OS.execute(_powershell_path(), ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Destination", destination, "-HelperDestination", helpers], output, true)

func build_module(cargo_manifest: String, output: Array) -> int:
	if DirAccess.make_dir_recursive_absolute(_configured_config_dir) != OK:
		return ERR_CANT_CREATE
	var script := "& { $ErrorActionPreference='Stop'; Add-Type -Path $args[1]; [WindowsNativeProcessControl]::PrepareDedicatedConsole(); $lease=$null; try { $cargo=(Get-Command cargo -ErrorAction Stop).Source; $lease=[WindowsNativeProcessControl]::Start($cargo,@('build','--manifest-path',$args[0],'--release','--target','wasm32-unknown-unknown'),(Split-Path $args[0] -Parent),$args[2]); if (-not $lease.Wait(300000)) { $lease.ForceTerminate() | Out-Null; $lease.Wait(5000) | Out-Null; exit 124 }; exit $lease.ExitCode } finally { if ($lease -and $lease.Liveness -eq 'Dead') { $lease.Dispose() }; [WindowsNativeProcessControl]::ReleaseDedicatedConsole() } }"
	return OS.execute(_powershell_path(), ["-NoProfile", "-NonInteractive", "-Command", script, cargo_manifest, _helper_path(), _configured_config_dir.path_join("native-build.log")], output, true)

func helperpath(supervisor: String) -> String:
	return supervisor.get_base_dir().path_join("WindowsNativeProcessControl.cs")

func configure(supervisor: String, runtime := "", cli := "", data_path := "", config_dir := "", manifest := "", lock_path := "") -> void:
	_configured_supervisor = supervisor
	_configured_runtime = runtime
	_configured_cli = cli
	_configured_data = data_path
	_configured_config_dir = config_dir
	_configured_manifest = manifest
	_configured_lock = lock_path

var _configured_supervisor := ""
var _configured_runtime := ""
var _configured_cli := ""
var _configured_data := ""
var _configured_config_dir := ""
var _configured_manifest := ""
var _configured_lock := ""

func _configure_from(supervisor: String) -> void:
	if _configured_supervisor.is_empty():
		configure(supervisor)

func self_test(supervisor: String) -> Dictionary:
	var report := capability_report()
	report["supervisor_present"] = FileAccess.file_exists(supervisor)
	report["control_helper_present"] = FileAccess.file_exists(helperpath(supervisor))
	report["ready"] = bool(report.supported) and bool(report.supervisor_present) and bool(report.control_helper_present)
	return report

func launch(supervisor: String, runtime: String, cli: String, module: String, host: String, database: String, data_path: String, config_path: String, lock_path: String, log_path: String, manifest_path: String, module_sha256: String, startup_nonce: String) -> Dictionary:
	configure(supervisor, runtime, cli, data_path, config_path, manifest_path, lock_path)
	if not supports_native_hosting():
		return {"ok": false, "error": "Windows native hosting requires Windows x86_64."}
	if host != "http://127.0.0.1:3001" or database.is_empty() or module_sha256.length() != 64 or not module_sha256.is_valid_hex_number():
		return {"ok": false, "error": "Native hosting requires localhost and a pinned module digest."}
	if supervisor.is_empty() or not FileAccess.file_exists(supervisor) or not FileAccess.file_exists(helperpath(supervisor)) or not FileAccess.file_exists(runtime) or not FileAccess.file_exists(cli):
		return {"ok": false, "error": "The verified Windows native distribution is not installed."}
	var pid := OS.create_process(_powershell_path(), _start_args(supervisor, runtime, cli, module, host, database, data_path, config_path, lock_path, log_path, manifest_path, module_sha256, startup_nonce), false)
	if pid <= 1:
		return {"ok": false, "error": "Could not launch the Windows native supervisor."}
	var started_at := _process_start_token(pid)
	return {"ok": true, "pid": pid, "started_at": started_at}

func health(host: String) -> bool:
	if host != "http://127.0.0.1:3001":
		return false
	var output: Array = []
	return OS.execute(_powershell_path(), ["-NoProfile", "-NonInteractive", "-Command", "try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 -Uri 'http://127.0.0.1:3001/v1/ping' | Out-Null; exit 0 } catch { exit 1 }"], output, true) == 0

func is_process_identity(pid: int, started_at: String, expected_binary: String, expected_sha256: String, expected_parent_pid := -1) -> bool:
	if not supports_native_hosting() or pid <= 1 or started_at.is_empty() or expected_binary.is_empty():
		return false
	var output: Array = []
	var result := OS.execute(_powershell_path(), ["-NoProfile", "-NonInteractive", "-Command", "& { $ErrorActionPreference='Stop'; Add-Type -Path $args[5]; [WindowsNativeProcessControl]::IsProcessIdentity([uint32]$args[0],$args[1],$args[2],$args[3],[int]$args[4]) }", str(pid), started_at, expected_binary, expected_sha256, str(expected_parent_pid), _helper_for_binary(expected_binary)], output, true)
	return result == 0 and not output.is_empty() and str(output[0]).strip_edges().to_lower() == "true"

func process_exists(pid: int) -> bool:
	if not supports_native_hosting() or pid <= 1:
		return false
	var output: Array = []
	var result := OS.execute(_powershell_path(), ["-NoProfile", "-NonInteractive", "-Command", "& { $ErrorActionPreference='Stop'; Add-Type -Path $args[1]; [WindowsNativeProcessControl]::LivenessForPid([uint32]$args[0]).ToString() }", str(pid), _helper_path()], output, true)
	if result != 0 or output.is_empty():
		return true # An unreadable process is unknown, never proof of death.
	return str(output[0]).strip_edges().to_lower() != "dead"

func terminate(pid: int, force: bool, started_at: String, expected_binary: String, expected_sha256: String, expected_parent_pid := -1) -> bool:
	if _configured_manifest.is_empty():
		return false
	if not is_process_identity(pid, started_at, expected_binary, expected_sha256, expected_parent_pid):
		return false
	var manifest := _find_owned_manifest(pid, started_at, expected_binary, expected_sha256, expected_parent_pid)
	if manifest.is_empty():
		return false
	var output: Array = []
	var verb := "force" if force else "stop"
	return OS.execute(_powershell_path(), ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", manifest.supervisor, verb, "-Manifest", manifest.path, "-SupervisorPid", str(manifest.pid), "-SupervisorCreationTime", str(manifest.started_at)], output, true) == 0

func cleanup_stale(supervisor: String, lock_path: String, manifest_path: String, manifest_sha256: String) -> bool:
	_configure_from(supervisor)
	if _configured_manifest.is_empty():
		_configured_manifest = manifest_path
	var output: Array = []
	return OS.execute(_powershell_path(), ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", supervisor, "cleanup", "-Data", _configured_data, "-Manifest", manifest_path, "-ManifestSha256", manifest_sha256], output, true) == 0

func get_autostart(supervisor: String, data_path: String) -> Dictionary:
	_configure_from(supervisor)
	var output: Array = []
	var script := "& { $ErrorActionPreference='Stop'; try { $s=New-Object -ComObject Schedule.Service; $s.Connect(); $t=$s.GetFolder('\\').GetTask($args[0]); if ($t.Definition.RegistrationInfo.Source -ne 'Continuum native' -or $t.Definition.RegistrationInfo.URI -ne $args[1]) { exit 3 }; if ($t.Enabled) { 'enabled' } else { 'disabled' }; exit 0 } catch { $e=$_.Exception; while ($e -and $e.HResult -ne -2147024894) { $e=$e.InnerException }; if ($e) { 'disabled'; exit 0 }; exit 2 } }"
	var code := OS.execute(_powershell_path(), ["-NoProfile", "-NonInteractive", "-Command", script, _task_name(data_path), _task_uri(data_path)], output, true)
	return {"ok": code == 0, "enabled": code == 0 and not output.is_empty() and str(output[0]).strip_edges() == "enabled", "error": "Could not read the native server logon task."}

func set_autostart(enabled: bool, supervisor: String, runtime: String, cli: String, module: String, host: String, database: String, data_path: String, config_path: String, lock_path: String, log_path: String, manifest_path: String, module_sha256: String, startup_nonce: String) -> Dictionary:
	configure(supervisor, runtime, cli, data_path, config_path, manifest_path, lock_path)
	if not supports_native_hosting():
		return {"ok": false, "error": "Windows native hosting is unavailable on this platform."}
	var task_path := OS.get_user_data_dir().path_join("Continuum/native/2.10.0/continuum-native-task.xml")
	if not enabled:
		var result := _task_operation("disable", task_path, "", data_path, supervisor)
		if bool(result.ok):
			DirAccess.remove_absolute(task_path)
		return result
	var xml := windows_task_xml(supervisor, runtime, cli, module, host.trim_prefix("http://"), database, data_path, config_path, lock_path, log_path, manifest_path, module_sha256, startup_nonce, _windows_user_id())
	if xml.is_empty():
		return {"ok": false, "error": "Autostart arguments failed Windows path validation."}
	DirAccess.make_dir_recursive_absolute(task_path.get_base_dir())
	var file := FileAccess.open(task_path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "Could not write the per-user Task Scheduler definition."}
	file.store_string(xml)
	file.close()
	return _task_operation("enable", task_path, xml, data_path, supervisor)

func windows_task_xml(supervisor: String, runtime: String, cli: String, module: String, host: String, database: String, data_path: String, config_path: String, lock_path: String, log_path: String, manifest_path: String, module_sha256: String, startup_nonce: String, service_user := "") -> String:
	if host != "127.0.0.1:3001" or not database.is_valid_identifier() or module_sha256.length() != 64 or not module_sha256.is_valid_hex_number():
		return ""
	for value in [supervisor, runtime, cli, module, data_path, config_path, lock_path, log_path, manifest_path, database, module_sha256, startup_nonce]:
		if str(value).is_empty() or str(value).contains("\n") or str(value).contains("\r") or str(value).contains('"'):
			return ""
	var encoded := []
	for arg in _start_args(supervisor, runtime, cli, module, "http://" + host, database, data_path, config_path, lock_path, log_path, manifest_path, module_sha256, startup_nonce):
		encoded.append(_quote(str(arg)))
	var user := service_user if not service_user.is_empty() else _windows_user_id()
	if user.is_empty():
		return ""
	var ps := _powershell_path()
	return "<?xml version=\"1.0\"?><Task xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\"><RegistrationInfo><Source>Continuum native</Source><URI>%s</URI></RegistrationInfo><Triggers><LogonTrigger><Enabled>true</Enabled><UserId>%s</UserId></LogonTrigger></Triggers><Principals><Principal id=\"Author\"><UserId>%s</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals><Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries></Settings><Actions Context=\"Author\"><Exec><Command>%s</Command><Arguments>%s</Arguments><WorkingDirectory>%s</WorkingDirectory></Exec></Actions></Task>" % [_xml_escape(_task_uri(data_path)), _xml_escape(user), _xml_escape(user), _xml_escape(ps), _xml_escape(" ".join(encoded)), _xml_escape(data_path)]

func _start_args(supervisor: String, runtime: String, cli: String, module: String, host: String, database: String, data_path: String, config_path: String, lock_path: String, log_path: String, manifest_path: String, module_sha256: String, startup_nonce: String) -> Array:
	return ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", supervisor, "start", "-Runtime", runtime, "-Cli", cli, "-Module", module, "-ListenAddress", host.trim_prefix("http://"), "-Database", database, "-Data", data_path, "-ConfigDir", config_path, "-Lock", lock_path, "-Log", log_path, "-Manifest", manifest_path, "-ModuleSha256", module_sha256, "-StartupNonce", startup_nonce]

func _task_operation(operation: String, task_path: String, xml: String, data_path: String, supervisor: String) -> Dictionary:
	# COM is used by the Windows release gate; schtasks output is localized and is not a state signal.
	var output: Array = []
	var command := "& { $ErrorActionPreference='Stop'; $s=New-Object -ComObject Schedule.Service; $s.Connect(); $f=$s.GetFolder('\\'); $existing=$null; try { $existing=$f.GetTask($args[1]) } catch { $e=$_.Exception; while ($e -and $e.HResult -ne -2147024894) { $e=$e.InnerException }; if (-not $e) { exit 2 } }; if ($existing) { $old=$existing.Definition; if ($old.RegistrationInfo.Source -ne 'Continuum native' -or $old.RegistrationInfo.URI -ne $args[6] -or $old.Actions.Count -ne 1) { exit 4 }; $oldAction=$old.Actions.Item(1); if ($oldAction.Type -ne 0 -or $oldAction.Path -ne $args[3] -or $oldAction.Arguments.IndexOf($args[7],[StringComparison]::OrdinalIgnoreCase) -lt 0) { exit 4 } }; if ($args[0] -eq 'disable') { if ($existing) { $f.DeleteTask($args[1],0) }; exit 0 }; $raw=Get-Content -Raw -LiteralPath $args[2]; $d=[xml]$raw; $sid=[string]$d.Task.Principals.Principal.UserId; $f.RegisterTask($args[1],$raw,6,$sid,$null,3,$null) | Out-Null; $t=$f.GetTask($args[1]); $actual=$t.Definition; if (-not $t.Enabled -or $actual.Principal.UserId -ne $sid -or $actual.Principal.LogonType -ne 3 -or $actual.Principal.RunLevel -ne 0 -or $actual.Actions.Count -ne 1 -or $actual.Triggers.Count -ne 1) { exit 3 }; $a=$actual.Actions.Item(1); $trigger=$actual.Triggers.Item(1); if ($a.Type -ne 0 -or $a.Path -ne $args[3] -or $a.Arguments -ne [string]$d.Task.Actions.Exec.Arguments -or $a.WorkingDirectory -ne $args[5] -or $trigger.Type -ne 9 -or -not $trigger.Enabled -or $trigger.UserId -ne $sid) { exit 3 }; exit 0 }"
	var result := OS.execute(_powershell_path(), ["-NoProfile", "-NonInteractive", "-Command", command, operation, _task_name(data_path), task_path, _powershell_path(), supervisor, data_path, _task_uri(data_path), _quote("-File") + " " + _quote(supervisor)], output, true)
	return {"ok": result == 0, "error": "Could not register or verify the per-user logon task."}

func _find_owned_manifest(pid: int, token: String, binary: String, sha: String, parent: int) -> Dictionary:
	if not FileAccess.file_exists(_configured_manifest):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(_configured_manifest))
	if not parsed is Dictionary or not same_data_path(str(parsed.get("data_dir", "")), _configured_data):
		return {}
	var supervisor_match: bool = int(parsed.get("pid", -1)) == pid and str(parsed.get("started_at", "")) == token \
		and binary.replace("\\", "/").to_lower() == _configured_supervisor.replace("\\", "/").to_lower() \
		and str(parsed.get("supervisor_sha256", "")) == sha
	var runtime_match: bool = int(parsed.get("runtime_pid", -1)) == pid and str(parsed.get("runtime_started_at", "")) == token \
		and binary.replace("\\", "/").to_lower() == _configured_runtime.replace("\\", "/").to_lower() \
		and str(parsed.get("runtime_sha256", "")) == sha and (parent <= 1 or int(parsed.get("runtime_parent_pid", -1)) == parent)
	if not supervisor_match and not runtime_match:
		return {}
	return {"path": _configured_manifest, "pid": parsed.pid, "started_at": parsed.started_at, "supervisor": _configured_supervisor}

func _process_start_token(pid: int) -> String:
	var output: Array = []
	var result := OS.execute(_powershell_path(), ["-NoProfile", "-NonInteractive", "-Command", "& { $ErrorActionPreference='Stop'; Add-Type -Path $args[1]; [WindowsNativeProcessControl]::CreationTokenForPid([uint32]$args[0]) }", str(pid), _helper_path()], output, true)
	return "" if result != 0 or output.is_empty() else str(output[0]).strip_edges()

func _powershell_path() -> String:
	var windir := OS.get_environment("WINDIR")
	var system_dir := "Sysnative" if not OS.get_environment("PROCESSOR_ARCHITEW6432").is_empty() else "System32"
	return windir.path_join(system_dir + "/WindowsPowerShell/v1.0/powershell.exe") if not windir.is_empty() else "powershell.exe"

func _windows_user_id() -> String:
	var output: Array = []
	var result := OS.execute(_powershell_path(), ["-NoProfile", "-NonInteractive", "-Command", "[Security.Principal.WindowsIdentity]::GetCurrent().User.Value"], output, true)
	return str(output[0]).strip_edges() if result == 0 and not output.is_empty() else ""

func _helper_path() -> String:
	var supervisor := _configured_supervisor if not _configured_supervisor.is_empty() else _default_supervisor()
	return helperpath(supervisor) if not supervisor.is_empty() else ""

func _default_supervisor() -> String:
	var local_app_data := OS.get_environment("LOCALAPPDATA")
	return local_app_data.path_join("Continuum/native/helpers/windows-supervisor.ps1") if not local_app_data.is_empty() else ""

func _helper_for_binary(binary: String) -> String:
	var candidate := binary.get_base_dir().path_join("WindowsNativeProcessControl.cs")
	return candidate if FileAccess.file_exists(candidate) else _helper_path()

func _quote(value: String) -> String:
	var result := '"'; var slashes := 0
	for character in value:
		if character == "\\": slashes += 1; continue
		if character == '"': result += "\\".repeat(slashes * 2 + 1) + '"'
		else: result += "\\".repeat(slashes) + character
		slashes = 0
	return result + "\\".repeat(slashes * 2) + '"'

func _task_name(data_path: String) -> String:
	var hashing := HashingContext.new(); hashing.start(HashingContext.HASH_SHA256); hashing.update(data_path.simplify_path().to_lower().to_utf8_buffer())
	return TASK_NAME + "-" + hashing.finish().hex_encode().left(16)

func _task_uri(data_path: String) -> String:
	return "urn:continuum:native:" + _task_name(data_path).sha256_text()

func _xml_escape(value: String) -> String:
	return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;").replace("'", "&apos;")
