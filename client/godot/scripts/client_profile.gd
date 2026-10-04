## Separate credential paths per client profile, including on the same colony.
class_name ContinuumClientProfile extends RefCounted

const NORMAL := "normal"
const ADMIN := "admin"
const DEVELOPER := "developer"

static func validated(profile: String) -> String:
	return profile if profile in [NORMAL, ADMIN, DEVELOPER] else NORMAL

static func token_path(profile: String, host: String, database: String, server_id := "") -> String:
	profile = validated(profile)
	var context := host + "/" + database
	if not server_id.is_empty(): context += "\nmanaged-server:" + server_id
	var key := context.md5_text()
	if profile == NORMAL:
		return "user://continuum_identity_%s.token" % key
	return "user://continuum_%s_identity_%s.token" % [profile, key]

## A freed port is not a credential identity. Legacy credentials are candidates
## for migration only after the target server authenticates them. This lookup
## grants no local lifecycle permissions and never creates a catalog.
static func configure_credentials(client: SpacetimeDBClient, profile: String, host: String,
		database: String, catalog: ContinuumNativeServerCatalog = null) -> void:
	var legacy := token_path(profile, host, database)
	client.token_save_path = legacy
	client.fallback_token_save_path = ""
	client.validate_cached_token = true
	client.recover_rejected_cached_token = false
	if catalog == null:
		var root := ContinuumNativeServerManager.native_root()
		if not FileAccess.file_exists(root.path_join("servers.json")): return
		catalog = ContinuumNativeServerCatalog.new()
		if catalog.load_from(root) != OK: return
	var endpoint := ContinuumServerEndpoint.parse(host)
	if endpoint.is_empty() or database.strip_edges().to_lower() != "continuum": return
	for entry in catalog.entries():
		var canonical := "http://127.0.0.1:%d" % int(entry.port)
		if str(endpoint.canonical) not in [canonical, "http://localhost:%d" % int(entry.port),
				"ws://127.0.0.1:%d" % int(entry.port), "ws://localhost:%d" % int(entry.port)]: continue
		client.token_save_path = token_path(profile, canonical, "continuum", str(entry.id))
		client.fallback_token_save_path = legacy
		client.recover_rejected_cached_token = true
		return
