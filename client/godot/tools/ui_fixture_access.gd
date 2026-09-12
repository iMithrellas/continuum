extends ContinuumAccess

func _init(_client: SpacetimeDBClient) -> void:
	pass

func start() -> void:
	_set_unknown()

func stop() -> void:
	pass

func set_role(role_name: String, can_operate: bool, admin: bool) -> void:
	_set_role(role_name, can_operate, admin)
