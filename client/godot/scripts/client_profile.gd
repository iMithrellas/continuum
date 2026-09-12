## Separate credential paths per client profile, including on the same colony.
class_name ContinuumClientProfile extends RefCounted

const NORMAL := "normal"
const ADMIN := "admin"

static func token_path(profile: String, host: String, database: String) -> String:
	if profile != NORMAL and profile != ADMIN:
		push_error("unknown Continuum client profile: %s" % profile)
		return "user://continuum_invalid_profile.token"
	var key := (host + "/" + database).md5_text()
	if profile == NORMAL:
		return "user://continuum_identity_%s.token" % key
	return "user://continuum_admin_identity_%s.token" % key
