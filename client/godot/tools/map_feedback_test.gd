## Replicated map feedback, intent exposure, cache invalidation, and hover input.
## Backend-free; use map_client_x11.py with -- --capture for PNG evidence.
extends Node

const Fixture = preload("res://tools/terrain_fixture.gd")
var failures := 0
var assertions := 0


func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error(message)


func region_for(map: ColonyMap, kind: int) -> Dictionary:
	for region: Dictionary in map._visible_regions:
		if region.kind == kind:
			return region
	return {}


func _ready() -> void:
	call_deferred("run")


func run() -> void:
	var previous := SpacetimeDB.Continuum.db
	var local := Fixture.database()
	local._tables["tile"][10] = ContinuumTile.create(10, 3, 1, ContinuumTileKind.create_farm(), true, -8, 2, 1, 6)
	local._tables["tile"][11] = ContinuumTile.create(11, 5, 1, ContinuumTileKind.create_farm(), true, -8, 1, 1, 6)
	local._tables["tile"][12] = ContinuumTile.create(12, 6, 0, ContinuumTileKind.create_forest(), true, -8, 2, 1, 6)
	local._tables["tile"][13] = ContinuumTile.create(13, 3, 3, ContinuumTileKind.create_empty(), true, -8, 1, 1, 1)
	local._tables["terrain"][10] = ContinuumTerrain.create(10, 0.8, 0.3, 0.5)
	local._tables["terrain"][12] = ContinuumTerrain.create(12, 0.1, 0.8, 0.2)
	local._tables["terrain"][13] = ContinuumTerrain.create(13, 0.6, 0.2, 0.75)
	local._tables["work_order"][1] = ContinuumWorkOrder.create(1, 10, ContinuumWorkType.create_farming(), 1, true)
	local._tables["work_order"][2] = ContinuumWorkOrder.create(2, 11, ContinuumWorkType.create_farming(), 3, false)
	var excavation: ContinuumExcavationDesignation = local._tables["excavation_designation"][1]
	excavation.priority = 1
	excavation.total_cells = 12
	excavation.completed_cells = 3
	Fixture.index_rows(local)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(768, 384)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var map := ColonyMap.new()
	map.size = Vector2(viewport.size)
	viewport.add_child(map)
	map.refresh()
	map.set_process(false)
	check(region_for(map, ContinuumTileKind.Options.farm).work_label == "PAUSED / ORDER HIGH", "mixed adjacent farms name order priority without promising current production")
	check(region_for(map, ContinuumTileKind.Options.forest).work_label == "NO ORDER", "productive facilities without orders say so directly on the map")
	check(region_for(map, ContinuumTileKind.Options.dining).work_label == "", "need facilities never acquire an invented production state")
	check(map._excavation_regions[0].status.contains("HIGH") and map._excavation_regions[0].status.contains("3/12 done"), "excavation captions use replicated priority and completed volume, not exposed area")
	check(map._get_tooltip(map.world_to_screen(Vector2(7.5, 3.5))).contains("3/12 done"), "hover exposes the same full designation progress")
	var farm_hover := map._get_tooltip(map.world_to_screen(Vector2(3.5, 1.5)))
	check(farm_hover.contains("Farming: 90% of baseline"), "farm hover uses 0.5 + fertility × moisture from its durable terrain row")
	check(farm_hover.contains("current worker productivity") and farm_hover.contains("hauled") and farm_hover.contains("stock policy can still suspend production"), "ecological potential and enabled-order badges do not promise current production or delivered stock")
	var forest_hover := map._get_tooltip(map.world_to_screen(Vector2(6.5, 0.5)))
	check(forest_hover.contains("Logging: 130% of baseline") and forest_hover.contains("Hunting: 130% of baseline") and not forest_hover.contains("decorative"), "forest cover drives both logging and hunting potential via 0.5 + density")
	check(map._get_tooltip(map.world_to_screen(Vector2(5.5, 1.5))).contains("terrain data unavailable"), "a facility missing ecology reports unknown instead of observed neutral yield")
	var land_hover := map._get_tooltip(map.world_to_screen(Vector2(3.5, 3.5)))
	check(land_hover.contains("Farming: 95% of baseline") and land_hover.contains("Logging: 70% of baseline") and land_hover.contains("Hunting: 70% of baseline"), "unbuilt land exposes farming and forestry potential before a build tool is chosen")
	var actor: ContinuumColonist = local._tables["colonist"][2]
	actor.name = "Mara"
	actor.goal = ContinuumGoal.create_haul()
	actor.activity = ContinuumActivity.create_travelling()
	actor.target_x = 7
	actor.target_y = 2
	actor.target_z = -8
	map.set_selected_colonist(actor.id)
	check(map.colonist_intent(actor) == "Haul · destination (7, 2, -8)", "intent describes exact replicated goal and xyz target")
	check(map.destination_visible(actor), "known exposed in-view destination gets a marker")
	check(map._get_tooltip(map.world_to_screen(Vector2(5.5, 2.5))).contains("Haul · destination (7, 2, -8)"), "hover adds actor goal and target to existing activity/cargo information")
	if "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless":
		await capture(viewport, "map-feedback-active.png")
	actor.target_x = 1
	check(not map.destination_visible(actor), "buried destination cannot project onto a nearer floor")
	actor.target_x = 7
	actor.target_z = 1
	check(not map.destination_visible(actor), "above-cut destination cannot project onto the visible floor")
	actor.target_z = -8
	actor.body_width = 2
	check(not map.destination_visible(actor), "whole-body destination exposure rejects a partly unknown/out-of-world footprint")
	actor.body_width = 1
	actor.goal = ContinuumGoal.create_nothing()
	check(not map.destination_visible(actor) and map.colonist_intent(actor) == "No current goal", "idle rows with stale coordinates never claim an active destination")
	actor.goal = ContinuumGoal.create_haul()
	map.set_interaction_mode(&"facility")
	map.facility_width = 2
	check(map.action_hint(Vector2i(3, 3)).contains("potential 95%"), "pre-click farm footprint caption includes ecological potential on unbuilt land")
	check(map.action_hint(Vector2i(4, 3)).contains("potential unknown"), "sparse physical terrain cannot borrow ecology from a neighbouring starter tile")
	map.set_build_kind(ContinuumTileKind.Options.forest)
	check(map.action_hint(Vector2i(3, 3)).contains("potential 70%"), "changing placement kind immediately switches the displayed ecology multiplier")
	var build_hover := map._get_tooltip(map.world_to_screen(Vector2(3.5, 3.5)))
	check(build_hover.contains("Placement anchor potential") and build_hover.contains("Logging: 70%") and build_hover.contains("Hunting: 70%") and not build_hover.contains("Farming:"), "placement hover explains the current build kind and identifies the sampled anchor")
	map.set_build_kind(ContinuumTileKind.Options.farm)
	map.set_interaction_mode(&"build")
	check(map.action_hint(Vector2i(3, 3)).contains("potential 95%"), "area-painting and whole-facility tools share the same pre-placement yield feedback")
	map.set_interaction_mode(&"facility")
	check(map.action_hint(Vector2i(2, 3)).contains("Mixed / unknown"), "pre-click footprint diagnoses mixed elevations")
	check(map.action_hint(Vector2i(7, 2)).contains("Mixed / unknown"), "pre-click footprint diagnoses bounds and unknown columns")
	check(map.action_hint(Vector2i(3, 1)).contains("Occupied"), "pre-click footprint reports replicated occupancy")
	check(map.action_hint(Vector2i(3, 3)).contains("click to request"), "clear local geometry invites a request without promising server approval")
	map.facility_height = 30
	check(map.action_hint(Vector2i(3, 3)).contains("clearance blocked"), "hover checks the actual requested height")
	map.facility_height = 6
	var motion := InputEventMouseMotion.new()
	motion.position = map.world_to_screen(Vector2(3.5, 3.5))
	map._gui_input(motion)
	check(map._hover_cell == Vector2i(3, 3) and not map._dragging, "mouse motion previews without arming an edit")
	map.pan_by(Vector2(24, 0))
	check(map._hover_cell == map._cell_at(motion.position), "stationary pointer remains aligned after camera changes")
	map.input_blocked = func(_point: Vector2) -> bool: return true
	map._gui_input(motion)
	check(map._hover_cell == null, "floating panel blocking clears pre-click feedback")
	map.input_blocked = Callable()
	map.fit_camera()
	map._gui_input(motion)
	if "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless":
		await capture(viewport, "map-feedback-ecology-before.png")
		check(map._preview_plate_cache.get("count", "").contains("potential 95%"), "placement draw measures the original ecology caption before a terrain update")
	var ecology_terrain_builds := map.terrain_view.terrain_build_count
	local._tables["terrain"][13] = ContinuumTerrain.create(13, 1.0, 0.9, 1.0)
	Fixture.index_rows(local)
	map.refresh({"terrain": true})
	check(map.action_hint(Vector2i(3, 3)).contains("potential 150%") and not map.action_hint(Vector2i(3, 3)).contains("95%"), "terrain-only row replacement immediately updates an already-hovered placement caption")
	check(map._get_tooltip(map.world_to_screen(Vector2(3.5, 3.5))).contains("Farming: 150% of baseline"), "tooltip ecology reads the new replicated resource rather than a stale cached row")
	check(map.terrain_view.terrain_build_count == ecology_terrain_builds, "ecology-only updates do not rebuild voxel rendering passes")
	if "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless":
		await capture(viewport, "map-feedback-ecology-after.png")
		check(map._preview_plate_cache.get("count", "").contains("potential 150%"), "stationary hover refreshes its measured caption when replicated ecology changes")
	map.set_interaction_mode(&"select")
	var topology := map._regions
	var terrain_builds := map.terrain_view.terrain_build_count
	var mask_builds := map.terrain_view.mask_build_count
	local._tables["work_order"][1].enabled = false
	map.refresh({"work_order": true})
	check(region_for(map, ContinuumTileKind.Options.farm).work_label == "PAUSED", "order-only replication updates region feedback immediately")
	check(map._regions == topology and map.terrain_view.terrain_build_count == terrain_builds and map.terrain_view.mask_build_count == mask_builds, "order-only updates reuse connectivity, terrain textures, and exposure masks")
	excavation.enabled = false
	map.refresh({"excavation_designation": true})
	check(map._excavation_regions[0].status.contains("PAUSED") and map._excavation_regions[0].status.contains("3/12 done"), "pausing an excavation preserves authoritative progress")
	local._tables["tile"][10].enabled = false
	map.refresh({"tile": true})
	check(region_for(map, ContinuumTileKind.Options.farm).work_label == "OFF / PAUSED", "facility-off and work-paused remain distinct states")
	map.set_cut(-9)
	check(map._visible_regions.is_empty(), "work labels never reveal buried facilities")
	map.set_cut(0)
	check(region_for(map, ContinuumTileKind.Options.farm).work_label == "OFF / PAUSED", "cut restoration restores current statuses without new order rows")
	if "--capture" in OS.get_cmdline_user_args():
		check(DisplayServer.get_name() != "headless", "capture requires a private rendering display")
		if DisplayServer.get_name() != "headless":
			await capture(viewport, "map-feedback-paused.png")
			check(map._actor_plate_cache.get("count", "").contains("destination"), "actual draw pass emits the actor intent caption")
			check(map._destination_plate_cache.get("title") == "DESTINATION", "actual draw pass emits the exposed target caption")
			map.set_selected_colonist(-1)
			map.set_interaction_mode(&"facility")
			map._gui_input(motion)
			await capture(viewport, "map-feedback-placement.png")
			check(map._preview_plate_cache.get("count", "").contains("click to request"), "actual draw pass emits the pre-click action caption")
			check(map._preview_plate_cache.get("count", "").contains("potential 150%"), "actual placement draw uses fresh ecology after a terrain-only update")
			viewport.size = Vector2i(360, 240)
			map.size = Vector2(viewport.size)
			map.set_interaction_mode(&"select")
			map.set_selected_colonist(actor.id)
			await capture(viewport, "map-feedback-narrow.png")
			check(map._actor_plate_cache.size.x <= 360 and map._destination_plate_cache.size.x <= 360, "transient text remains bounded on a narrow map")
	var source := SpacetimeDB.Continuum.db
	SpacetimeDB.Continuum.db = null
	check(not map.destination_visible(actor) and map.action_hint(Vector2i(3, 3)).is_empty(), "provider detach fails closed for all new feedback queries")
	check(map._work_orders_by_tile.is_empty() and map._visible_regions.is_empty() and map._hover_cell == null and map._actor_plate_cache.is_empty(), "provider detach clears bounded presentation caches")
	SpacetimeDB.Continuum.db = source
	map.refresh({"colonist": true})
	check(region_for(map, ContinuumTileKind.Options.farm).work_label == "OFF / PAUSED", "selective refresh after reattach installs the current work snapshot")
	viewport.free()
	SpacetimeDB.Continuum.db = previous
	local.free()
	print("MAP_FEEDBACK_%s: %d assertions" % ["PASS" if failures == 0 else "FAIL", assertions])
	get_tree().quit(0 if failures == 0 else 1)


func capture(viewport: SubViewport, filename: String) -> void:
	for frame in 4:
		await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://build/map-client")
	viewport.get_texture().get_image().save_png("res://build/map-client/" + filename)
