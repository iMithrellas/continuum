## Backend-free contract for persisted font settings and reference metrics.
extends SceneTree

const Settings = preload("res://scripts/client_settings.gd")
const Metrics = preload("res://scripts/ui_metrics.gd")
const Layout = preload("res://scripts/workspace_layout.gd")

func _init() -> void:
	var path := "user://ui_scale_test_%d.cfg" % Time.get_ticks_usec()
	var settings := Settings.new()
	settings.font_size = 999
	assert(settings.save_to(path) == OK)
	var restored := Settings.new()
	assert(restored.load_from(path) and restored.font_size == Settings.MAX_FONT_SIZE)
	restored.font_size = Settings.MIN_FONT_SIZE
	assert(restored.save_to(path) == OK)
	assert(Metrics.new(Settings.MIN_FONT_SIZE).font(13) == Settings.MIN_FONT_SIZE)
	assert(Metrics.new(Settings.MAX_FONT_SIZE).font(13) == Settings.MAX_FONT_SIZE)
	assert(Metrics.new(13).min_size(280, 180) == Vector2(280, 180))
	assert(Metrics.new(24).min_size(280, 180).x > Layout.MIN_SIZE.x)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("UI_SCALE_PASS persisted bounds reference metrics minima")
	quit(0)
