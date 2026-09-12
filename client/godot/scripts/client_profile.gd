## Token profile paths. Profiles are deliberately separate even on the same colony.
class_name ContinuumClientProfile extends RefCounted

const NORMAL := "normal"
const ADMIN := "admin"

static func token_path(profile: String, host: String, database: String) -> String:
	if profile != NORMAL and profile != ADMIN:
		push_error("unknown Continuum client profile: %s" % profile)
		return "user://continuum_invalid_profile.token"
	return "user://continuum_%s_identity_%s.token" % [profile, (host.trim_suffix("/") + "/" + database.to_lower()).md5_text()]
