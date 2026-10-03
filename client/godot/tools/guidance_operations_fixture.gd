## Contract-only operation explanation fixture, not a production model stub.
extends RefCounted

static func snapshot(tiles: Array, orders: Array, colonists: Array, stacks: Array,
		resources: Dictionary, _policies: Array = []) -> Array[Dictionary]:
	return [{"work": 0, "name": "Farming", "state": "Ready", "summary": "%d facilities, %d orders, %d people, %d stacks" % [tiles.size(), orders.size(), colonists.size(), stacks.size()],
		"detail": "Stored food: %.1f; inspect access before increasing work" % resources.food,
		"suggested_action": "Inspect farm access", "focus_tile_id": 3,
		"ready_workers": 1, "active_orders": 1, "ground_amount": 0, "stored_amount": resources.food}]
