## Shared address validation and history normalization. Credential keys use raw inputs.
class_name ContinuumServerEndpoint
extends RefCounted

const DEFAULT_PORTS := {"http": 80, "https": 443, "ws": 80, "wss": 443}

static func parse(endpoint: String) -> Dictionary:
	var raw := endpoint.strip_edges()
	var marker := raw.find("://")
	if marker <= 0: return {}
	var scheme := raw.substr(0, marker).to_lower()
	if not DEFAULT_PORTS.has(scheme): return {}
	var authority := raw.substr(marker + 3)
	if authority.is_empty() or authority.contains("/") or authority.contains("?") or authority.contains("#") or authority.contains("@"): return {}
	var host := ""
	var port := -1
	if authority.begins_with("["):
		var close := authority.find("]")
		if close <= 1: return {}
		host = authority.substr(0, close + 1)
		var address := host.substr(1, host.length() - 2)
		if not address.contains(":") or not address.is_valid_ip_address(): return {}
		if authority.length() > close + 1:
			if authority[close + 1] != ":": return {}
			port = _port(authority.substr(close + 2))
			if port < 0: return {}
	else:
		var colon := authority.find(":")
		if colon >= 0:
			host = authority.substr(0, colon)
			port = _port(authority.substr(colon + 1))
			if port < 0: return {}
		else:
			host = authority
		if not _valid_dns_or_ipv4(host): return {}
	# IPv6 spelling stays intact; only DNS hostnames are case-folded.
	var canonical := scheme + "://" + (host if host.begins_with("[") else host.to_lower())
	if port >= 0 and port != DEFAULT_PORTS[scheme]: canonical += ":%d" % port
	return {"endpoint": raw, "scheme": scheme, "canonical": canonical}

static func valid_database(value: String) -> bool:
	var canonical := value.to_lower()
	if canonical.length() < 1 or canonical.length() > 128: return false
	if not ((canonical[0] >= "a" and canonical[0] <= "z") or (canonical[0] >= "0" and canonical[0] <= "9")): return false
	if not ((canonical[-1] >= "a" and canonical[-1] <= "z") or (canonical[-1] >= "0" and canonical[-1] <= "9")): return false
	var previous_dash := false
	for character in canonical:
		var alphanumeric := (character >= "a" and character <= "z") or (character >= "0" and character <= "9")
		if not alphanumeric and character != "-": return false
		if character == "-" and previous_dash: return false
		previous_dash = character == "-"
	return true

static func _valid_dns_or_ipv4(host: String) -> bool:
	if host.is_empty() or host.length() > 253 or host.begins_with(".") or host.ends_with("."): return false
	for label in host.split("."):
		if label.is_empty() or label.length() > 63 or label.begins_with("-") or label.ends_with("-"): return false
		for character in label.to_lower():
			if not ((character >= "a" and character <= "z") or (character >= "0" and character <= "9") or character == "-"): return false
	return true

static func _port(value: String) -> int:
	if value.is_empty() or value.length() > 5 or (value.length() > 1 and value.begins_with("0")): return -1
	for character in value:
		if character < "0" or character > "9": return -1
	var port := int(value)
	return port if port > 0 and port <= 65535 else -1
