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
	assert(Metrics.new(Settings.MIN_FONT_SIZE).font(13) == 11)
	assert(Metrics.new(Settings.MAX_FONT_SIZE).font(13) == Settings.MAX_FONT_SIZE)
	assert(Metrics.new(13).min_size(280, 180) == Vector2(280, 180))
	assert(Metrics.new(24).min_size(280, 180).x > Layout.MIN_SIZE.x)
	var large := Metrics.new(24)
	assert(Layout.to_pixels([0.5, 0.5, 0.01, 0.01], Vector2(1600, 900), large).size == large.min_size(280, 180))
	for old_font: int in range(10, 25):
		var legacy := ConfigFile.new()
		legacy.set_value("ui", "font_size", old_font)
		legacy.set_value("server", "host", "http://example.test")
		assert(legacy.save(path) == OK)
		var migrated := Settings.new()
		assert(migrated.load_from(path) == "loaded")
		assert(migrated.ui_scale_percent in Settings.UI_SCALES)
		assert(migrated.ui_scale_percent == Settings.legacy_ui_scale(old_font))
		assert(migrated.ui_scale_percent >= 100 and migrated.font_size == old_font)
		assert(migrated.server_host == "http://example.test")
	settings.ui_scale_percent = 150
	settings.reduced_motion = true
	assert(settings.save_to(path) == OK)
	assert(restored.load_from(path) == "loaded" and restored.ui_scale_percent == 150 and restored.reduced_motion)
	var window := Window.new()
	restored.apply_ui_scale(window)
	assert(window.content_scale_factor == 1.5 and restored.font_size == 13)
	assert(restored.ui_metrics().scale == 1 and restored.ui_metrics().font(10) == 11)
	assert(restored.clone().reduced_motion and restored.clone().ui_scale_percent == 150)
	window.free()
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
