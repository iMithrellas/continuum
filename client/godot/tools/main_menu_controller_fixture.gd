extends "res://scripts/main.gd"

class ClientFixture extends ContinuumModuleClient:
	var live := false
	var connects := 0
	var disconnects := 0
	var subscriptions := 0
	var discards := 0

	func is_connected_db() -> bool:
		return live

	func connect_db(host: String, database: String, _options: SpacetimeDBConnectionOptions = null):
		connects += 1
		base_url = host
		database_name = database.to_lower()
		live = true
		connected.emit(PackedByteArray([1, 2, 3]), "fixture-token")

	func disconnect_db(_clear := false):
		disconnects += 1
		live = false

	func subscribe(queries: PackedStringArray) -> SpacetimeDBSubscription:
		subscriptions += 1
		var handle := SpacetimeDBSubscription.create(self, subscriptions, queries)
		add_child(handle)
		return handle

	func discard_subscription(handle: SpacetimeDBSubscription) -> void:
		discards += 1
		handle.queue_free()

var starts := 0
var use_sdk_setup := false

func _has_cli_connection() -> bool:
	return false

func _setup_native_controller() -> void:
	pass

func _cli_option(option: String, fallback: String) -> String:
	if option == "--workspace-file":
		return ClientSettings.path_from_args() + ".workspace.json"
	return super._cli_option(option, fallback)

func _start_configured_client(client: ContinuumModuleClient, _generation: int) -> void:
	starts += 1
	if use_sdk_setup:
		super._start_configured_client(client, _generation)
		return
	if client is ClientFixture:
		client.token_save_path = "user://main_menu_fixture.token"
		client.connect_db(_host, _database)
