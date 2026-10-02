## Presentation topology only. Never substitutes for a durable facility identity.
## Connectivity is global, four-neighbour, and partitioned by kind + feet z.
class_name MapRegions
extends RefCounted

const NEIGHBOURS := [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]

static func build(footprints: Array) -> Array[Dictionary]:
	var groups := {}
	for footprint: Dictionary in footprints:
		var key := Vector2i(int(footprint.kind), int(footprint.z))
		if not groups.has(key):
			groups[key] = {}
		var rect: Rect2i = footprint.rect
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				groups[key][Vector2i(x, y)] = true
	var result: Array[Dictionary] = []
	var keys: Array = groups.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	for key: Vector2i in keys:
		var remaining: Dictionary = groups[key].duplicate()
		var seeds: Array = remaining.keys()
		seeds.sort_custom(_before)
		for seed: Vector2i in seeds:
			if not remaining.has(seed):
				continue
			var cells := {seed: true}
			var queue: Array[Vector2i] = [seed]
			remaining.erase(seed)
			var index := 0
			var bounds := Rect2i(seed, Vector2i.ONE)
			while index < queue.size():
				var cell := queue[index]
				index += 1
				bounds = bounds.merge(Rect2i(cell, Vector2i.ONE))
				for direction: Vector2i in NEIGHBOURS:
					var adjacent := cell + direction
					if remaining.has(adjacent):
						remaining.erase(adjacent)
						cells[adjacent] = true
						queue.append(adjacent)
			var edges: Array[PackedVector2Array] = []
			for cell: Vector2i in queue:
				var corners := [Vector2(cell), Vector2(cell + Vector2i.RIGHT), Vector2(cell + Vector2i.ONE), Vector2(cell + Vector2i.DOWN)]
				for side in 4:
					if not cells.has(cell + NEIGHBOURS[side]):
						edges.append(PackedVector2Array([corners[side], corners[(side + 1) % 4]]))
			# Horizontal runs let sharp designation hatches render without scanning
			# the entire occupied grid again on every moving-actor frame.
			queue.sort_custom(_before)
			var runs: Array[Rect2i] = []
			for cell: Vector2i in queue:
				if not runs.is_empty() and runs[-1].position.y == cell.y and runs[-1].end.x == cell.x:
					var run := runs[-1]
					run.size.x += 1
					runs[-1] = run
				else:
					runs.append(Rect2i(cell, Vector2i.ONE))
			result.append({"kind": key.x, "z": key.y, "anchor": seed, "count": cells.size(), "bounds": bounds, "cells": cells, "edges": edges, "runs": runs})
	return result

static func _before(a: Vector2i, b: Vector2i) -> bool:
	return a.y < b.y or (a.y == b.y and a.x < b.x)
