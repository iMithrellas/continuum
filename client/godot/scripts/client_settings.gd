## Local client preferences. This never contains replicated colony state.
class_name ClientSettings
extends RefCounted

const DEFAULT_FONT_SIZE := 13
const MIN_FONT_SIZE := 10
const MAX_FONT_SIZE := 24
const UI_SCALES := [100, 125, 150, 175]
const SAVE_PATH := "user://continuum_settings.cfg"
const HISTORY_PATH := "user://continuum_connection_history.json"
const FAVORITES_PATH := "user://continuum_connection_favorites.json"

var font_size := DEFAULT_FONT_SIZE
var ui_scale_percent := 100
var reduced_motion := false
var server_host := ""
var database := ""
var diagnostics_enabled := false
var diagnostics_graph_enabled := false
var native_autostart := false
var last_load_status := "missing"


static func path_from_args(fallback := SAVE_PATH) -> String:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--settings-file="):
			return argument.substr("--settings-file=".length())
	return fallback


static func companion_path_from_settings(
	settings_path: String, suffix: String, default_path: String
) -> String:
	if settings_path == SAVE_PATH:
		return default_path
	return settings_path + suffix


func load_from(path := path_from_args()) -> String:
	var config := ConfigFile.new()
	var error := config.load(path)
	if error == ERR_FILE_NOT_FOUND:
		last_load_status = "missing"
		return last_load_status
	if error != OK:
		last_load_status = "unreadable"
		return last_load_status
	font_size = clampi(
		int(config.get_value("ui", "font_size", DEFAULT_FONT_SIZE)), MIN_FONT_SIZE, MAX_FONT_SIZE
	)
	ui_scale_percent = normalize_ui_scale(
		int(config.get_value("ui", "scale_percent", legacy_ui_scale(font_size)))
	)
	reduced_motion = bool(config.get_value("ui", "reduced_motion", false))
	server_host = _safe_string(config.get_value("server", "host", ""))
	database = _safe_string(config.get_value("server", "database", ""))
	diagnostics_enabled = bool(config.get_value("diagnostics", "enabled", false))
	diagnostics_graph_enabled = bool(config.get_value("diagnostics", "graph_enabled", false))
	native_autostart = bool(config.get_value("native", "autostart", false))
	last_load_status = "loaded"
	return last_load_status


func save_to(path := path_from_args()) -> Error:
	var config := ConfigFile.new()
	config.set_value("ui", "font_size", clampi(font_size, MIN_FONT_SIZE, MAX_FONT_SIZE))
	config.set_value("ui", "scale_percent", normalize_ui_scale(ui_scale_percent))
	config.set_value("ui", "reduced_motion", reduced_motion)
	config.set_value("server", "host", server_host.strip_edges())
	config.set_value("server", "database", database.strip_edges())
	config.set_value("diagnostics", "enabled", diagnostics_enabled)
	config.set_value("diagnostics", "graph_enabled", diagnostics_graph_enabled)
	config.set_value("native", "autostart", native_autostart)
	return config.save(path)


func remember_server(host: String, db: String, path := path_from_args()) -> Error:
	server_host = host.strip_edges()
	database = db.strip_edges()
	return save_to(path)


func clone() -> ClientSettings:
	var copy := ClientSettings.new()
	copy.font_size = font_size
	copy.ui_scale_percent = ui_scale_percent
	copy.reduced_motion = reduced_motion
	copy.server_host = server_host
	copy.database = database
	copy.diagnostics_enabled = diagnostics_enabled
	copy.diagnostics_graph_enabled = diagnostics_graph_enabled
	copy.native_autostart = native_autostart
	copy.last_load_status = last_load_status
	return copy


static func _safe_string(value: Variant) -> String:
	return value if value is String else ""


static func normalize_ui_scale(value: int) -> int:
	var nearest := 100
	for candidate: int in UI_SCALES:
		if absi(candidate - value) < absi(nearest - value):
			nearest = candidate
	return nearest


## Legacy sizes below the 13px baseline must never shrink the new interface.
static func legacy_ui_scale(value: int) -> int:
	return normalize_ui_scale(maxi(100, roundi(float(value) / DEFAULT_FONT_SIZE * 100)))


## The Window is the sole scaling authority; all token measurements stay logical.
func apply_ui_scale(window: Window) -> void:
	ui_scale_percent = normalize_ui_scale(ui_scale_percent)
	font_size = DEFAULT_FONT_SIZE
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_factor = float(ui_scale_percent) / 100.0


func ui_metrics() -> UiMetrics:
	return UiMetrics.new(DEFAULT_FONT_SIZE)
