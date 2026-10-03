## Wire-independent bounded subscription owner. Backend supplies SQL and snapshot
## adapters. All edits for a source region must be included in the same snapshot.
class_name TerrainStream
extends RefCounted

signal changed
signal failed(message: String)
signal overview_requested(rect: Rect2i, stride: int, cut: int)

var max_resident := 64
var max_pending := 4
var acknowledgement_seconds := 15.0
var model: LayeredTerrainModel
var client: Variant
var epoch := 0
var generation := 0
var query_adapter := Callable()
var snapshot_adapter := Callable()
var _wanted: Dictionary = {}
var _entries: Dictionary = {}
var _request_serial := 0
var mode: StringName = &"detail"
var manage_physical := true
var eviction_adapter := Callable()
var _pinned: Dictionary = {}

func attach(value_client: Variant, value_model: LayeredTerrainModel, session_epoch: int,
		world_generation: int, queries: Callable, snapshot: Callable) -> void:
	stop()
	client = value_client
	model = value_model
	epoch = session_epoch
	generation = world_generation
	query_adapter = queries
	snapshot_adapter = snapshot

func current(value_client: Variant, session_epoch: int, world_generation: int) -> bool:
	return client == value_client and epoch == session_epoch and generation == world_generation

func request_frame(rect: Rect2i, pixels_per_cell: float, cut: int) -> void:
	if model == null or client == null:
		return
	var area := rect.intersection(model.bounds())
	var edge := model.source_edge
	var start := Vector2i(floori(area.position.x / float(edge)), floori(area.position.y / float(edge)))
	var finish := Vector2i(ceili(area.end.x / float(edge)), ceili(area.end.y / float(edge)))
	var count := maxi(0, finish.x - start.x) * maxi(0, finish.y - start.y)
	_wanted.clear()
	for coordinate: Vector2i in _pinned:
		_wanted[coordinate] = true
	if pixels_per_cell < 1.0 or count > max_resident:
		mode = &"overview"
		var stride := 1
		while stride * maxf(pixels_per_cell, 0.0001) < 2.0:
			stride *= 2
		overview_requested.emit(area, stride, cut)
	else:
		mode = &"detail"
		for y in range(start.y, finish.y):
			for x in range(start.x, finish.x):
				if _wanted.size() < max_resident:
					_wanted[Vector2i(x, y)] = true
	for coordinate: Vector2i in _entries.keys():
		if not _wanted.has(coordinate):
			_release(coordinate)
	_pump()

func _pump() -> void:
	if client == null or not client.is_connected_db() or not query_adapter.is_valid():
		return
	var pending := 0
	for entry: Dictionary in _entries.values():
		if not entry.applied:
			pending += 1
	for coordinate: Vector2i in _wanted:
		if pending >= max_pending or _entries.size() >= max_resident:
			break
		if _entries.has(coordinate):
			continue
		var queries: PackedStringArray = query_adapter.call(coordinate, model.source_edge, generation)
		if queries.is_empty():
			failed.emit("Terrain query adapter returned no queries.")
			return
		var handle: Variant = client.subscribe(queries)
		if handle.error != OK:
			failed.emit("Terrain subscription failed (%d)." % handle.error)
			return
		_request_serial += 1
		var serial := _request_serial
		_entries[coordinate] = {"handle": handle, "applied": false, "releasing": false, "seconds": 0.0, "serial": serial}
		if manage_physical:
			model.set_chunk_complete(coordinate, false)
		handle.applied.connect(_applied.bind(coordinate, serial, client, epoch, generation))
		handle.end.connect(_ended.bind(coordinate, serial, client, epoch, generation))
		pending += 1

func _matches(coordinate: Vector2i, serial: int, owner: Variant, session_epoch: int, world_generation: int) -> bool:
	return current(owner, session_epoch, world_generation) and _entries.has(coordinate) and _entries[coordinate].serial == serial

func _applied(coordinate: Vector2i, serial: int, owner: Variant, session_epoch: int, world_generation: int) -> void:
	if not _matches(coordinate, serial, owner, session_epoch, world_generation):
		return
	_entries[coordinate].applied = true
	if not _wanted.has(coordinate):
		_release(coordinate)
		return
	if not snapshot_adapter.is_valid() or not bool(snapshot_adapter.call(model, coordinate, owner, generation)):
		_wanted.erase(coordinate)
		failed.emit("Terrain snapshot is incomplete or invalid.")
		_release(coordinate)
		return
	if manage_physical:
		model.set_chunk_complete(coordinate, true)
	changed.emit()
	_pump()

func _release(coordinate: Vector2i) -> void:
	if not _entries.has(coordinate):
		return
	_evict(coordinate)
	var entry: Dictionary = _entries[coordinate]
	# SDK unsubscribe acknowledgements require an applied handle in current_subscriptions.
	if not entry.applied or entry.releasing:
		return
	entry.releasing = true
	if client.is_connected_db():
		var result: int = entry.handle.unsubscribe()
		if result != OK:
			failed.emit("Terrain unsubscribe failed (%d)." % result)
	else:
		client.discard_subscription(entry.handle)
		_entries.erase(coordinate)

func _ended(coordinate: Vector2i, serial: int, owner: Variant, session_epoch: int, world_generation: int) -> void:
	if not _matches(coordinate, serial, owner, session_epoch, world_generation):
		return
	var expected: bool = _entries[coordinate].releasing
	_evict(coordinate)
	_entries.erase(coordinate)
	if not expected:
		_wanted.erase(coordinate)
		failed.emit("Terrain subscription ended before completion.")
	changed.emit()
	_pump()

func tick(delta: float) -> void:
	for coordinate: Vector2i in _entries.keys():
		var entry: Dictionary = _entries[coordinate]
		if entry.applied and not entry.releasing:
			continue
		entry.seconds += maxf(0.0, delta)
		if entry.seconds > acknowledgement_seconds:
			failed.emit("Terrain subscription acknowledgement timed out; reconnect required.")
			entry.seconds = -INF

func stop() -> void:
	_wanted.clear()
	_pinned.clear()
	var old_client: Variant = client
	client = null
	for coordinate: Vector2i in _entries.keys():
		var handle: Variant = _entries[coordinate].handle
		if model != null:
			_evict(coordinate)
		if old_client != null:
			if old_client.is_connected_db():
				if _entries[coordinate].applied:
					handle.unsubscribe()
				else:
					# Finish releasing even if the owning session stopped meanwhile.
					handle.applied.connect(func() -> void: handle.unsubscribe(), CONNECT_ONE_SHOT)
			else:
				old_client.discard_subscription(handle)
	_entries.clear()
	query_adapter = Callable()
	snapshot_adapter = Callable()

func resident_count() -> int:
	return _entries.size()

func _evict(coordinate: Vector2i) -> void:
	if manage_physical:
		model.evict_source_chunk(coordinate)
	if eviction_adapter.is_valid():
		eviction_adapter.call(coordinate)

func complete(coordinate: Vector2i) -> bool:
	return _entries.has(coordinate) and _entries[coordinate].applied and not _entries[coordinate].releasing

func active_coordinates() -> Array:
	var result: Array = []
	for coordinate: Vector2i in _entries:
		if complete(coordinate) and _wanted.has(coordinate):
			result.append(coordinate)
	return result

func pin_selection(rect: Rect2i) -> void:
	_pinned.clear()
	if model == null or rect.get_area() <= 0 or rect.get_area() > LayeredTerrainModel.MAX_SELECTION_CELLS:
		return
	var area := rect.intersection(model.bounds())
	for y in range(floori(area.position.y / float(model.source_edge)), ceili(area.end.y / float(model.source_edge))):
		for x in range(floori(area.position.x / float(model.source_edge)), ceili(area.end.x / float(model.source_edge))):
			if _pinned.size() >= max_resident:
				return
			_pinned[Vector2i(x, y)] = true
