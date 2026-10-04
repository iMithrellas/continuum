## Actual ColonyMap screenshots and cache/frame timings in private X11 only.
extends Node


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		get_tree().quit(1)
		return
	var phase := "after"
	var edge := 128
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--phase="):
			phase = arg.trim_prefix("--phase=")
		if arg.begins_with("--edge="):
			edge = int(arg.trim_prefix("--edge="))
	var previous := SpacetimeDB.Continuum.db
	var fixture = preload("res://tools/world_art_fixture.gd")
	var directory := "res://build/world-art/" + phase
	DirAccess.make_dir_recursive_absolute(directory)
	for resolution in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
		var local: LocalDatabase = fixture.database(128 if edge > 256 else edge)
		var viewport := SubViewport.new()
		viewport.size = resolution
		viewport.disable_3d = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(viewport)
		var map := ColonyMap.new()
		map.size = Vector2(resolution)
		viewport.add_child(map)
		map.set_process(false)
		var start := Time.get_ticks_usec()
		map.refresh()
		if edge > 256:
			fixture.expand_sparse_snapshot(map, local, edge)
		print(
			(
				"ART_PROFILE %s edge=%d resolution=%s initial_ms=%.2f"
				% [phase, edge, resolution, (Time.get_ticks_usec() - start) / 1000.0]
			)
		)
		var zooms := [
			{"name": "near", "cell": 40.0},
			{"name": "mid", "cell": 16.0},
			{"name": "far", "cell": 4.0}
		]
		if edge > 256:
			zooms.append({"name": "overview", "cell": 0.5})
		for zoom in zooms:
			start = Time.get_ticks_usec()
			map.zoom_at(zoom.cell / map._cell_size(), map.size * 0.5)
			if edge > 256:
				assert(fixture.install_camera_frame(map))
			var camera_ms := (Time.get_ticks_usec() - start) / 1000.0
			for frame in 6:
				await RenderingServer.frame_post_draw
			var builds := map.terrain_view.terrain_build_count
			var masks := map.terrain_view.mask_build_count
			var times: Array[float] = []
			for frame in 60:
				start = Time.get_ticks_usec()
				await RenderingServer.frame_post_draw
				times.append((Time.get_ticks_usec() - start) / 1000.0)
			times.sort()
			var pixels := 0
			for layer in map.terrain_view.terrain_layers():
				if layer.texture != null:
					pixels += int(layer.texture.get_width() * layer.texture.get_height())
			print(
				(
					"ART_PROFILE %s edge=%d resolution=%s zoom=%s cell=%.1f camera_ms=%.2f frame_p50=%.2f frame_p95=%.2f terrain_pixels=%d pages=%d exposed_cells=%d idle_rebuilds=%d idle_masks=%d"
					% [
						phase,
						edge,
						resolution,
						zoom.name,
						map._cell_size(),
						camera_ms,
						times[30],
						times[57],
						pixels,
						map.terrain_view._active_pages.size(),
						map.terrain_model.surfaces.size(),
						map.terrain_view.terrain_build_count - builds,
						map.terrain_view.mask_build_count - masks
					]
				)
			)
			viewport.get_texture().get_image().save_png(
				"%s/%d-%dx%d-%s.png" % [directory, edge, resolution.x, resolution.y, zoom.name]
			)
		viewport.free()
		local.free()
	SpacetimeDB.Continuum.db = previous
	print("WORLD_ART_EVIDENCE_PASS")
	get_tree().quit()
