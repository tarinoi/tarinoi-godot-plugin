class_name TarinoiDataVersion
extends RefCounted

## Checks each synced document's data_version against the format this plugin
## was built for. Semver contract (promised by the Tarinoi data format):
##   MAJOR — breaking; this plugin can no longer read the data. Fatal.
##   MINOR — additive, backward-compatible. Logged as a warning.
##   PATCH — cosmetic; no shape change. Logged for debugging only.
## A null/empty data_version means a pre-versioning legacy document and is
## not checked.
##
## One instance is expected to live for the duration of a single sync, so
## repeated occurrences of the same data_version are only logged once.

const SUPPORTED_VERSION := "1.0.0"

# data_version String → "" (compatible) or the fatal error message (major mismatch).
var _logged: Dictionary = {}


## Returns "" if compatible (or unversioned/legacy). Returns a non-empty
## error message on a MAJOR mismatch — callers must treat that as fatal and
## abort the sync.
func check(data_version: Variant) -> String:
	if data_version == null:
		return ""
	var dv := str(data_version)
	if dv.is_empty():
		return ""
	if _logged.has(dv):
		return _logged[dv]

	var parsed := _parse(dv)
	if parsed.is_empty():
		TarinoiLogger.warn("TarinoiDataVersion: unparseable data_version '%s' — skipping check" % dv)
		_logged[dv] = ""
		return ""

	var supported := _parse(SUPPORTED_VERSION)
	var result := ""
	if parsed[0] != supported[0]:
		result = "TarinoiDataVersion: MAJOR data format mismatch — plugin supports %s, data is %s. Update the plugin." \
			% [SUPPORTED_VERSION, dv]
		TarinoiLogger.error(result)
	elif parsed[1] != supported[1]:
		TarinoiLogger.warn("TarinoiDataVersion: minor data format mismatch — plugin supports %s, data is %s" \
			% [SUPPORTED_VERSION, dv])
	elif parsed[2] != supported[2]:
		TarinoiLogger.debug("TarinoiDataVersion: patch data format mismatch — plugin supports %s, data is %s" \
			% [SUPPORTED_VERSION, dv])

	_logged[dv] = result
	return result


## Parses "X.Y.Z" into [major, minor, patch] ints, or [] if malformed.
func _parse(version: String) -> Array:
	var parts := version.split(".")
	if parts.size() != 3:
		return []
	var result: Array = []
	for p in parts:
		if not (p as String).is_valid_int():
			return []
		result.append(int(p))
	return result
