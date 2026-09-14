## Local client preferences. This never contains replicated colony state.
class_name ClientSettings
extends RefCounted

const DEFAULT_FONT_SIZE := 13
const MIN_FONT_SIZE := 10
const MAX_FONT_SIZE := 24
const SAVE_PATH := "user://continuum_settings.cfg"

var font_size := DEFAULT_FONT_SIZE
var server_host := ""
var database := ""

static func path_from_args(fallback := SAVE_PATH) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--settings-file="):
			return argument.substr("--settings-file=".length())
	return fallback

func load_from(path := path_from_args()) -> bool:
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return true
	font_size = clampi(int(config.get_value("ui", "font_size", DEFAULT_FONT_SIZE)), MIN_FONT_SIZE, MAX_FONT_SIZE)
	server_host = _safe_string(config.get_value("server", "host", ""))
	database = _safe_string(config.get_value("server", "database", ""))
	return true

func save_to(path := path_from_args()) -> Error:
	var config := ConfigFile.new()
	config.set_value("ui", "font_size", clampi(font_size, MIN_FONT_SIZE, MAX_FONT_SIZE))
	config.set_value("server", "host", server_host.strip_edges())
	config.set_value("server", "database", database.strip_edges())
	return config.save(path)

func remember_server(host: String, db: String, path := path_from_args()) -> Error:
	server_host = host.strip_edges()
	database = db.strip_edges()
	return save_to(path)

static func _safe_string(value: Variant) -> String:
	return value if value is String else ""
