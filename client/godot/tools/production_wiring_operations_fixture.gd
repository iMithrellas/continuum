## Record the real guidance inputs, then delegate to the actual advisory projection.
extends RefCounted

static var policies_seen: Array = []
static var context_seen: Dictionary = {}


static func snapshot(
	tiles: Array,
	orders: Array,
	colonists: Array,
	stacks: Array,
	resources: Dictionary,
	policies: Array = [],
	context: Dictionary = {}
) -> Array[Dictionary]:
	policies_seen = policies.duplicate(true)
	context_seen = context.duplicate(true)
	return ColonyOperationsModel.snapshot(
		tiles, orders, colonists, stacks, resources, policies, context
	)
