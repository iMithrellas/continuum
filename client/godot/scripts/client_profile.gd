## Separate credential paths per client profile, including on the same colony.
class_name ContinuumClientProfile extends RefCounted

const NORMAL := "normal"
const ADMIN := "admin"
const DEVELOPER := "developer"

static func validated(profile: String) -> String:
	return profile if profile in [NORMAL, ADMIN, DEVELOPER] else NORMAL

static func token_path(profile: String, host: String, database: String) -> String:
	profile = validated(profile)
	var key := (host + "/" + database).md5_text()
	if profile == NORMAL:
		return "user://continuum_identity_%s.token" % key
	return "user://continuum_%s_identity_%s.token" % [profile, key]
