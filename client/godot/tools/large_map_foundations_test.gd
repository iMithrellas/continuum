extends SceneTree

class FakeHandle extends RefCounted:
	signal applied
	signal end
	var error := OK
	var unsubscribes := 0
	func unsubscribe() -> int:
		unsubscribes += 1
		return OK

class FakeClient extends RefCounted:
	var online := true
	var handles: Array = []
	var disconnected := 0
	var discarded := 0
	func is_connected_db() -> bool:
		return online
	func subscribe(_queries: PackedStringArray) -> FakeHandle:
		var handle := FakeHandle.new()
		handles.append(handle)
		return handle
	func discard_subscription(_handle: Variant) -> void:
		discarded += 1
	func disconnect_db() -> void:
		disconnected += 1
		online = false

var checks := 0
var failures := 0

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var legacy := LayeredTerrainModel.new()
	var lower := PackedInt32Array()
	lower.resize(4096)
	lower.fill(1)
	var upper := PackedInt32Array()
	upper.resize(4096)
	legacy.sync({"width": 2048, "height": 2048, "min_z": -16, "max_z": 15}, [
		{"chunk_x": 0, "chunk_y": 0, "chunk_z": -1, "materials": lower, "revision": 1},
		{"chunk_x": 0, "chunk_y": 0, "chunk_z": 0, "materials": upper, "revision": 1}], [{"id": 1, "opaque": true}])
	check(legacy.surfaces.size() == 256 and legacy.query_count == 256,
		"legacy sync prepares immediate renderer surfaces from resident columns only, not 2048 squared bounds")
	var model := LayeredTerrainModel.new()
	model.set_geometry({"width": 2048, "height": 2048, "min_z": -16, "max_z": 15})
	model.set_materials([{"id": 1, "name": "soil", "opaque": true}])
	model.configure_sources(64, func(payload: Dictionary, cell: Vector3i) -> int:
		return int(payload.material) if cell.z <= int(payload.floor) else 0)
	model.apply_source_chunk(Vector2i(16, 16), {"floor": -1, "material": 1}, 1)
	check(model.query_count == 0 and model.surfaces.is_empty(), "initialization never scans 2048 squared")
	var xy := Vector2i(1024, 1024)
	check(model.material_at(Vector3i(1024, 1024, -1)) == -1, "baseline unavailable before edit snapshot applied")
	check(model.surface_at(xy) == null, "pending baseline cannot become a physical pick")
	model.set_chunk_complete(Vector2i(16, 16), true)
	check(model.surface_at(xy) == Vector3i(1024, 1024, -1), "source edge 64 exact physical ray")
	var before := model.query_count
	model.set_cut(5)
	check(model.query_count == before, "cut invalidation visits no world cells")
	var frame := model.frame_samples(Rect2i(1024, 1024, 16, 16))
	check(frame.samples.size() == 256 and model.query_count - before == 256, "detail work bounded by queried viewport")
	before = model.query_count
	frame = model.frame_samples(Rect2i(0, 0, 2048, 2048), 1, 100)
	check(frame.truncated and frame.samples.size() == 100 and model.query_count - before <= 100, "full-world accidental detail request capped")
	check(model.capture_selection(Rect2i(0, 0, 2048, 2048)).is_empty(), "selection capped at 4096")
	model.set_cut(0)
	var selection := model.capture_selection(Rect2i(xy, Vector2i.ONE))
	var edit := PackedInt32Array()
	edit.resize(4096)
	model.apply_edit_chunk(Vector3i(64, 64, -1), edit)
	check(model.surface_at(xy) == null and not model.selection_valid(selection), "dense sparse edit replaces baseline including air and invalidates selection")
	model.remove_edit_chunk(Vector3i(64, 64, -1))
	check(model.surface_at(xy) != null, "edit deletion falls back only in completed region")
	model.evict_source_chunk(Vector2i(16, 16))
	check(model.material_at(Vector3i(1024, 1024, -1)) == -1 and not model.selection_valid(selection), "eviction invalidates physical selection")

	var owner := FakeClient.new()
	var stream := TerrainStream.new()
	stream.max_resident = 4
	stream.max_pending = 2
	var snapshots := [0]
	var queries := func(coordinate: Vector2i, edge: int, version: int) -> PackedStringArray:
		return PackedStringArray(["FAKE %s %d %d" % [coordinate, edge, version]])
	var snapshot := func(target: LayeredTerrainModel, coordinate: Vector2i, _owner: Variant, _generation: int) -> bool:
		snapshots[0] += 1
		target.apply_source_chunk(coordinate, {"floor": -1, "material": 1}, 1)
		return true
	stream.attach(owner, model, 7, 9, queries, snapshot)
	stream.request_frame(Rect2i(1024, 1024, 128, 128), 32.0, 0)
	check(owner.handles.size() == 2, "bounded concurrent subscriptions")
	owner.handles[0].applied.emit()
	check(owner.handles.size() == 3 and snapshots[0] == 1, "snapshot application opens one bounded queue slot")
	var overview := [0]
	stream.overview_requested.connect(func(_rect: Rect2i, stride: int, _cut: int) -> void:
		overview[0] = stride)
	stream.request_frame(Rect2i(0, 0, 2048, 2048), 0.25, 0)
	check(overview[0] == 8 and stream.mode == &"overview" and owner.handles.size() == 3, "fit requests overview not whole-world physical subscriptions")
	check(owner.handles[0].unsubscribes == 1, "live applied subscriptions really unsubscribe")
	owner.handles[1].applied.emit()
	check(owner.handles[1].unsubscribes == 1 and snapshots[0] == 1, "late departing snapshot unsubscribes without ingest")
	var other := FakeClient.new()
	stream.attach(other, model, 8, 10, queries, snapshot)
	owner.handles[2].applied.emit()
	check(snapshots[0] == 1 and owner.handles[2].unsubscribes == 1, "old client epoch snapshot cannot mutate new model")
	stream.request_frame(Rect2i(0, 0, 64, 64), 32.0, 0)
	other.online = false
	stream.stop()
	check(other.discarded == 1, "offline subscriptions locally discarded")
	var timeout_owner := FakeClient.new()
	var errors := [0]
	stream.failed.connect(func(_message: String) -> void: errors[0] += 1)
	stream.attach(timeout_owner, model, 10, 11, queries, snapshot)
	stream.request_frame(Rect2i(0, 0, 64, 64), 32.0, 0)
	stream.tick(16.0)
	stream.tick(16.0)
	check(errors[0] == 1, "acknowledgement timeout is actionable and emitted once")
	timeout_owner.handles[0].end.emit()
	check(errors[0] == 2 and stream.resident_count() == 0, "asynchronous subscription end fails closed without retry loop")
	timeout_owner.handles[0].applied.emit()
	check(not model.coverage_ready(Rect2i(0, 0, 1, 1)), "late ended snapshot cannot authorize unknown terrain")
	stream.stop()

	var loading := WorldLoadingState.new()
	loading.begin(owner, 7, 9)
	loading.bootstrap_applied(owner, 7, 9, true)
	loading.server_progress(owner, 7, 9, "Generating columns", 128, 1024, false)
	check(loading.progress_fraction() == 0.125 and not loading.playable, "truthful committed server progress gates play")
	loading.server_progress(other, 8, 10, "Ready", 1024, 1024, true)
	check(not loading.playable and loading.completed == 128, "stale progress cannot restore readiness")
	loading.server_progress(owner, 7, 9, "Ready", 1024, 1024, true)
	check(loading.phase == "Loading nearby terrain" and not loading.playable, "world readiness distinct from local snapshot")
	loading.terrain_applied(owner, 7, 9, true)
	check(loading.playable, "ready existing world immediately finishes without timer")
	loading.begin(other, 8, 10)
	loading.bootstrap_applied(other, 8, 10, false)
	loading.terrain_applied(other, 8, 10, true)
	check(loading.playable, "explicit legacy capability absent bypasses missing generation row")
	loading.begin(other, 8, 10)
	loading.bootstrap_applied(other, 8, 10, true)
	loading.fail("Generation state unavailable")
	check(not loading.playable and not loading.error.is_empty(), "missing supported state fails rather than permanent spinner")
	loading.disconnect_current()
	check(other.disconnected == 1 and owner.disconnected == 0, "cancel disconnects only current client")
	var ui := Control.new()
	root.add_child(ui)
	var overlay := WorldLoadingOverlay.new()
	loading.begin(owner, 7, 9)
	overlay.attach(ui, loading)
	check(overlay.visible and not overlay._progress.visible, "unknown total shows no fabricated progress")
	loading.server_progress(owner, 7, 9, "Generating", 1, 4, false)
	check(overlay._progress.visible and overlay._progress.value == 25.0, "overlay renders real server progress")
	ui.free()
	print("LARGE_MAP_FOUNDATIONS_%s: %d assertions" % ["PASS" if failures == 0 else "FAIL", checks])
	quit(0 if failures == 0 else 1)
