## Typed replicated rows to presentation dictionaries. No SDK calls or mutations.
class_name UiData
extends RefCounted

const Models = preload("res://ui/components/models.gd")

static func duration(game_seconds: float) -> String:
	var minutes := maxi(0, int(game_seconds / 60.0))
	return "%d gameh %02dm" % [minutes / 60, minutes % 60]


static func colonist(row: ContinuumColonist, session: SessionObservations, selected: bool) -> Dictionary:
	var role := "Produce + haul" if row.haul_role.value == ContinuumHaulRole.Options.both else ContinuumHaulRole.parse_enum_name(row.haul_role.value).capitalize()
	var data := {"id": row.id, "name": row.name, "state": ContinuumActivity.parse_enum_name(row.activity.value).capitalize(), "job": "%s · %s" % [ContinuumWorkType.parse_enum_name(row.work.value).capitalize(), role], "cargo": "Empty hands", "selected": selected, "target": {"colonist_id": row.id}, "need_trends": {}}
	if row.carried_amount > 0.0:
		data.cargo = "%.1f %s" % [row.carried_amount, ContinuumResourceKind.parse_enum_name(row.carried_kind.value)]
		data.cargo_amount = row.carried_amount
		data.cargo_kind = ContinuumResourceKind.parse_enum_name(row.carried_kind.value)
	for descriptor: Array in Models.NEEDS:
		var label: String = descriptor[0]
		var field: String = descriptor[1]
		data[field] = row.get(field)
		var trend := session.need_trend(row.id, label)
		if trend.available:
			data.need_trends[field] = {"trend": {"up": "rising", "stable": "flat", "down": "falling"}[trend.direction], "trend_horizon": "last observed game hour"}
	return data


static func alert(row: ContinuumAlert, clock: Variant, can_acknowledge: bool) -> Dictionary:
	var age := "Age unavailable"
	if clock is float or clock is int:
		if float(clock) >= row.raised_game_seconds:
			age = duration(float(clock) - row.raised_game_seconds) + " ago"
	return {"id": row.id, "code": row.code, "level": ["notice", "warn", "critical"][clampi(row.severity.value, 0, 2)], "message": row.message, "title": row.message, "time": row.raised_game_seconds, "time_label": age, "acknowledged": row.acknowledged, "can_acknowledge": can_acknowledge}


static func event(row: ContinuumEventLog) -> Dictionary:
	# Backend messages are literal history; no actor/source claims or text parsing.
	return {"id": row.id, "message": row.message, "level": ["notice", "warn", "critical"][clampi(row.severity.value, 0, 2)], "day": row.day, "time_label": "%02d:%02d" % [row.hour, row.minute], "time": row.game_seconds}
