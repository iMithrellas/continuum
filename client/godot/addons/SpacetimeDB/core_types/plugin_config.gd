extends Resource
class_name SpacetimeDBPluginConfig

@export var autoload_name: StringName = "SpacetimeDB"
@export var uri: StringName = "http://127.0.0.1:3000"
@export var module_configs: Dictionary[String, SpacetimeDBModuleConfig] = {}
