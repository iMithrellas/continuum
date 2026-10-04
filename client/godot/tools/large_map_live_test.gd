## Actual Main + generated SDK on an explicitly owned private production module.
extends Node
var failures := 0
var assertions := 0
var main: Control
var phases := {}


func check(value: bool, message: String) -> void:
	assertions += 1
	if not value:
		failures += 1
		push_error(message)


func _ready() -> void:
	call_deferred("run")


func wait_for(predicate: Callable, message: String) -> bool:
	var deadline := Time.get_ticks_msec() + 60000
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		if main._large_world != null:
			phases[main._large_world.loading.phase] = true
			if not main._large_world.loading.error.is_empty():
				push_error(main._large_world.loading.error)
				break
		await get_tree().process_frame
	var success: bool = predicate.call()
	if not success:
		print(
			(
				"LIVE_WAIT_DEBUG mode=%s overview=%d wanted=%d active=%d outstanding=%d pendingSDK=%d error=%s"
				% [
					main.map.terrain_model.presentation_mode,
					main._large_world.overview.rows.size(),
					main._large_world.overview._stream._wanted.size(),
					main._large_world.overview._stream.active_coordinates().size(),
					main._large_world.overview._stream.outstanding_count(),
					SpacetimeDB.Continuum._pending_subscriptions.size(),
					main._large_world.loading.error
				]
			)
		)
	check(success, message)
	return success


func run() -> void:
	var host := ""
	var database := ""
	var disconnect_loading := false
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--stdb-host="):
			host = argument.trim_prefix("--stdb-host=")
		if argument.begins_with("--stdb-db="):
			database = argument.trim_prefix("--stdb-db=")
		if argument == "--disconnect-loading":
			disconnect_loading = true
	if not host.begins_with("http://127.0.0.1:") or host.ends_with(":3001") or database.is_empty():
		push_error("explicit private loopback runtime required, never port3001")
		get_tree().quit(1)
		return
	main = preload("res://scenes/main.tscn").instantiate()
	main.set_script(preload("res://tools/main_menu_controller_fixture.gd"))
	main.use_sdk_setup = true
	add_child(main)
	await get_tree().process_frame
	main.configure_connection(host, database, "stream-private", false)
	var near_start := Time.get_ticks_msec()
	if disconnect_loading:
		if not await wait_for(
			func() -> bool: return main._large_world.client != null and not main._state_ready,
			"actual bootstrap reaches non-playable loading"
		):
			main.leave_session()
			get_tree().quit(1)
			return
		main._large_world.tick(0.0)
		var expired: WeakRef = weakref(main._subscription)
		main.leave_session()
		await get_tree().create_timer(16.0).timeout
		check(
			(
				expired.get_ref() == null
				and not main._state_ready
				and not main.map.is_processing_input()
				and main._menu.visible
			),
			"real loading Disconnect remains cold after freed bootstrap timer deadline"
		)
		print(
			(
				"LARGE_MAP_LIVE_DISCONNECT_%s assertions=%d"
				% ["PASS" if failures == 0 else "FAIL", assertions]
			)
		)
		main.queue_free()
		get_tree().quit(0 if failures == 0 else 1)
		return
	if not await wait_for(
		func() -> bool: return main._state_ready,
		"actual Main reaches Ready plus exact nearby snapshot"
	):
		main.leave_session()
		get_tree().quit(1)
		return
	var client: ContinuumModuleClient = SpacetimeDB.Continuum
	var session: LargeWorldSession = main._large_world
	print(
		(
			"LIVE_PERF near_ready_msec=%d frames=%d map_size=%s"
			% [Time.get_ticks_msec() - near_start, session.rendered_frames, main.map.size]
		)
	)
	var state: ContinuumWorldGeneration = client.db.world_generation.id.find(0)
	check(
		(
			state != null
			and state.ready
			and state.width == 2048
			and state.height == 2048
			and state.phase.value == 5
		),
		"generated production Ready metadata"
	)
	check(state.starter_x == 1012 and state.starter_y == 1012, "authoritative centered colony")
	check(
		session.compact and session.loading.playable and not main._world_overlay.visible,
		"actual compact overlay completes only after coverage"
	)
	check(client.db.my_role.iter()[0] is ContinuumMembership, "actual Membership decoder")
	check(
		not client.db.terrain.iter().is_empty(),
		"operational ecology remains subscribed in fresh world"
	)
	check(
		(
			not client.db.terrain_column_chunk.iter().is_empty()
			and client.db.terrain_column_chunk.iter().size() <= 64
		),
		"actual source rows bounded"
	)
	check(
		main.map.terrain_model.surface_at(Vector2i(1024, 1024)) == Vector3i(1024, 1024, -1),
		"actual authored apron is exact"
	)
	check(session.detail.outstanding_count() <= 4, "bounded actual source requests")
	var detail_start := Time.get_ticks_msec()
	var detail_frames := session.rendered_frames
	var detail_queries: int = main.map.terrain_model.query_count
	var detail_cell: float = maxf(main.map.size.x / 240.0, main.map.size.y / 120.0)
	main.map.zoom_at(detail_cell / main.map._cell_size(), main.map.size * 0.5)
	main.map.pan_by(main.map.size * 0.5 - main.map.world_to_screen(Vector2(1536, 1536)))
	if not await wait_for(
		func() -> bool:
			return (
				session.detail.mode == &"detail"
				and session.detail._wanted.size() >= 16
				and session.detail.active_coordinates().size() == session.detail._wanted.size()
				and main.map.terrain_model.surface_at(Vector2i(1536, 1536)) != null
			),
		"ordinary far detail viewport completes exact source snapshots"
	):
		main.leave_session()
		get_tree().quit(1)
		return
	await get_tree().process_frame
	var detail_elapsed := Time.get_ticks_msec() - detail_start
	print(
		(
			"LIVE_PERF detail_jump_msec=%d sources=%d exact_cells=%d frames=%d ray_queries=%d pending=%d"
			% [
				detail_elapsed,
				session.detail._wanted.size(),
				main.map.visible_grid_rect().get_area(),
				session.rendered_frames - detail_frames,
				main.map.terrain_model.query_count - detail_queries,
				main.map.terrain_view.pending_samples
			]
		)
	)
	check(
		detail_elapsed < 30000 and main.map.terrain_view.pending_samples == 0,
		"ordinary detail settles inside thirty-second regression ceiling"
	)
	var fit_start := Time.get_ticks_msec()
	var fit_frames := session.rendered_frames
	main.map.fit_camera()
	if not await wait_for(
		func() -> bool:
			return (
				main.map.terrain_model.presentation_mode == &"overview"
				and session.overview.rows.size() == session.overview._stream._wanted.size()
				and not session.overview.rows.is_empty()
			),
		"actual Fit overview snapshots acknowledge"
	):
		main.leave_session()
		get_tree().quit(1)
		return
	await get_tree().process_frame
	var fit_elapsed := Time.get_ticks_msec() - fit_start
	print(
		(
			"LIVE_PERF fit_msec=%d lod=%d rows=%d samples=%d frames=%d pending=%d"
			% [
				fit_elapsed,
				session.overview.lod,
				session.overview.rows.size(),
				main.map.terrain_view._frame.samples.size(),
				session.rendered_frames - fit_frames,
				main.map.terrain_view.pending_samples
			]
		)
	)
	check(
		fit_elapsed < 15000,
		"ordinary authored Fit settles inside fifteen-second regression ceiling"
	)
	check(
		(
			client.db.terrain_overview_chunk.iter().size() <= 256
			and session.overview.rows.size() <= 256
		),
		"actual SDK overview residency bounded"
	)
	check(
		main.map.terrain_view.is_overview() and main.map.entity_descriptors().is_empty(),
		"actual authored overview does not expose entities"
	)
	check(
		main.map.terrain_view.pending_samples == 0,
		"actual complete overview uses no stale or pending representatives"
	)
	for change in 32:
		main.map.set_cut(-1 if change % 2 == 0 else -4)
		session.tick(0.0)
	check(
		(
			client._pending_subscriptions.size() <= 8
			and session.overview._stream.outstanding_count() <= 256
		),
		"rapid actual cut replacements do not multiply pending SDK handles"
	)
	main.map.set_cut(0)
	main.map.focus_detail_at(main.map.world_to_screen(Vector2(1024.5, 1024.5)))
	if not await wait_for(
		func() -> bool:
			return (
				main.map.terrain_model.presentation_mode == &"detail"
				and session.detail.complete(Vector2i(32, 32))
				and session.detail.active_coordinates().size() == session.detail._wanted.size()
			),
		"actual return from overview restores exact viewport snapshots"
	):
		main.leave_session()
		get_tree().quit(1)
		return
	check(
		main.map.terrain_model.surface_at(Vector2i(1024, 1024)) == Vector3i(1024, 1024, -1),
		"actual returning source retains exact floor"
	)
	await get_tree().process_frame
	check(
		main.map.terrain_view.pending_samples == 0,
		"actual exact frame settles without pending samples"
	)
	print(
		(
			"LARGE_MAP_LIVE_%s assertions=%d phases=%s sources=%d overview=%d frames=%d"
			% [
				"PASS" if failures == 0 else "FAIL",
				assertions,
				phases.keys(),
				client.db.terrain_column_chunk.iter().size(),
				client.db.terrain_overview_chunk.iter().size(),
				session.rendered_frames
			]
		)
	)
	main.leave_session()
	main.queue_free()
	get_tree().quit(0 if failures == 0 else 1)
