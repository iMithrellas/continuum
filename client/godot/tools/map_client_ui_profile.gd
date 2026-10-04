## Isolate per-tick Main UI work using the same cached map in both runs.
## Optional --main-script=res://build/map-client/main-before.gd loads a reviewed
## git snapshot of Main; no original/dirty worktree is ever loaded or edited.
extends Node


func subtree_size(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += subtree_size(child)
	return count


func sample(main: Control, label: String, colonists_changed: bool) -> void:
	var samples: Array[float] = []
	var new_nodes := 0
	for iteration in 30:
		main._on_table_changed("config")
		main._on_table_changed("colony")
		if colonists_changed:
			main._on_table_changed("colonist")
		var before := {}
		var boxes: Array = [main._colonist_box, main._alert_box, main._excavation_list]
		for box in boxes:
			for child in box.get_children():
				before[child.get_instance_id()] = true
		var start := Time.get_ticks_usec()
		main._refresh()
		samples.append((Time.get_ticks_usec() - start) / 1000.0)
		for box in boxes:
			for child in box.get_children():
				if not before.has(child.get_instance_id()):
					new_nodes += subtree_size(child)
		await get_tree().process_frame
	samples.sort()
	var total := 0.0
	for cost in samples:
		total += cost
	print(
		(
			"UI_PROFILE %s n=30 mean_ms=%.3f p95_ms=%.3f max_ms=%.3f created_nodes=%d"
			% [label, total / 30, samples[28], samples.back(), new_nodes]
		)
	)


func _ready() -> void:
	var previous := SpacetimeDB.Continuum.db
	var fixture := preload("res://tools/map_client_profile.gd").new()
	fixture.edge = 128
	var local: LocalDatabase = fixture.database()
	fixture.free()
	var main := preload("res://scenes/main.tscn").instantiate()
	var script_path := "current"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--main-script="):
			script_path = arg.trim_prefix("--main-script=")
			main.set_script(load(script_path))
	add_child(main)
	main.set_process(false)
	main.map.set_process(false)
	main.map.refresh()
	main._state_ready = true
	main._refresh()
	await get_tree().process_frame
	await get_tree().process_frame
	print(
		(
			"UI_PROFILE environment main=%s edge=128 display=%s cached_map=true"
			% [script_path, DisplayServer.get_name()]
		)
	)
	await sample(main, "ordinary_tick", true)
	await sample(main, "config_only_tick", false)
	main.free()
	SpacetimeDB.Continuum.db = previous
	local.free()
	print("MAP_CLIENT_UI_PROFILE_DONE")
	get_tree().quit()
