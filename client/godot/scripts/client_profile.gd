## Token profile paths. Profiles are deliberately separate even on the same colony.
class_name ContinuumClientProfile extends RefCounted

const NORMAL := "normal"
const ADMIN := "admin"

static func token_path(profile: String, host: String, database: String) -> String:
	if profile != NORMAL and profile != ADMIN:
		push_error("unknown Continuum client profile: %s" % profile)
		return "user://continuum_invalid_profile.token"
	var key := (host + "/" + database).md5_text()
	if profile == NORMAL:
		# Preserve the existing main-client identity without migration or copying.
		return "user://continuum_identity_%s.token" % key
	return "user://continuum_admin_identity_%s.token" % key
