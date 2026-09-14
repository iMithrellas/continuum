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
	var large := Metrics.new(24)
	assert(Layout.to_pixels([0.5, 0.5, 0.01, 0.01], Vector2(1600, 900), large).size == large.min_size(280, 180))
	var corrupt := path + ".bad"
	var bad_file := FileAccess.open(corrupt, FileAccess.WRITE)
	bad_file.store_string("[broken")
	bad_file.close()
	var bad := Settings.new()
	assert(bad.load_from(corrupt) == "unreadable")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(corrupt))
	print("UI_SCALE_PASS persisted bounds reference metrics minima")
	quit(0)
