extends SceneTree

func _initialize() -> void:
	var adapter = load("res://scripts/native_server_windows_adapter.gd").new()
	adapter.configure("C:/Users/test user/Continuum/windows-supervisor.ps1", "C:/Users/test user/Continuum/runtime.exe", "C:/Users/test user/Continuum/spacetime.exe", "C:/Users/test user/data", "C:/Users/test user/config", "C:/Users/test user/server.json", "C:/Users/test user/data/.continuum-native.lock")
	var xml: String = adapter.windows_task_xml("C:/Program Files/Continuum/supervisor.ps1", "C:/Program Files/Continuum/spacetime.exe", "C:/Program Files/Continuum/cli.exe", "C:/Users/é/module.wasm", "127.0.0.1:3001", "continuum", "C:/Users/test user/data", "C:/Users/test user/config", "C:/Users/test user/data.lock", "C:/Users/test user/server.log", "C:/Users/test user/server.json", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "nonce-1", "Mithrel")
	_assert(not xml.is_empty(), "valid Unicode and space-containing paths produce a task")
	_assert(xml.contains("&quot;C:/Program Files/Continuum/supervisor.ps1&quot;"), "task XML quotes executable paths")
	_assert(xml.contains("RunLevel>LeastPrivilege"), "task is non-elevated")
	_assert(xml.contains("LogonTrigger"), "task starts at user logon")
	_assert(xml.contains("-ConfigDir"), "task passes the manager config directory")
	_assert(xml.contains("WorkingDirectory"), "task records its working directory")
	var args: Array = adapter._start_args("supervisor", "runtime", "cli", "module", "http://127.0.0.1:3001", "continuum", "data", "C:/Users/test user/config", "lock", "log", "manifest", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "nonce")
	_assert(args[args.find("-ConfigDir") + 1] == "C:/Users/test user/config", "launch passes config directory, not a directory named cli.toml")
	_assert(adapter.helperpath("C:/Users/test user/Continuum/windows-supervisor.ps1") == "C:/Users/test user/Continuum/WindowsNativeProcessControl.cs", "helper is resolved beside the configured supervisor")
	_assert(adapter.runtime_path("C:/Program Files/Continuum") == "C:/Program Files/Continuum/spacetimedb-standalone.exe", "runtime path selects the Windows executable")
	_assert(adapter.windows_task_xml("C:/bad\"path", "runtime", "cli", "module", "127.0.0.1:3001", "continuum", "data", "config", "lock", "log", "manifest", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "nonce") == "", "quoted paths are rejected")
	_assert(adapter.windows_task_xml("supervisor", "runtime", "cli", "module", "0.0.0.0:3001", "continuum", "data", "config", "lock", "log", "manifest", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "nonce") == "", "non-local endpoints are rejected")
	print("NATIVE_SERVER_WINDOWS_ADAPTER_PASS")
	quit(0)

func _assert(value: bool, message: String) -> void:
	if not value:
		printerr("FAIL: " + message)
		quit(1)
