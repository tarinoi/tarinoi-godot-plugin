@tool
class_name TarinoiCodegen

# Reads the Tarinoi SQLite database and writes four GDScript stub files:
#   tarinoi_functions.gd  — one inner class per function collection
#   tarinoi_variables.gd  — one inner class per variable collection
#   tarinoi_lists.gd      — nested constants for list option keys
#   tarinoi_entities.gd   — constants for entity names
#
# Validates existing generated files before writing. ERRORs block the write.
# WARNINGs are logged but codegen proceeds.

var _db: TarinoiDB
var _errors: Array[String] = []
var _warnings: Array[String] = []


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Generate all four files. Returns false if errors blocked the write.
func run(db: TarinoiDB) -> bool:
	_db = db
	_errors.clear()
	_warnings.clear()

	var fns    := _load_functions()
	var vars   := _load_variables()
	var lists  := _load_lists()
	var ents   := _load_entities()

	var output_path: String = ProjectSettings.get_setting(
		"tarinoi/codegen/output_path", "res://bindings/generated/")
	if not output_path.ends_with("/"):
		output_path += "/"

	_validate_functions(fns, output_path)
	_validate_variables(vars, output_path)

	_flush_diagnostics()
	if not _errors.is_empty():
		push_error("Tarinoi codegen: %d error(s) — files not written. Fix mismatches or delete generated files and re-run." % _errors.size())
		return false

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_path))
	var header := _make_header()
	_write_file(output_path + "tarinoi_functions.gd", _gen_functions(fns, header))
	_write_file(output_path + "tarinoi_variables.gd", _gen_variables(vars, header))
	_write_file(output_path + "tarinoi_lists.gd",     _gen_lists(lists, header))
	_write_file(output_path + "tarinoi_entities.gd",  _gen_entities(ents, header))
	print("Tarinoi codegen: wrote 4 files to %s" % output_path)
	return true


## Validate without writing. Useful for CI / pre-commit checks.
func validate_only(db: TarinoiDB) -> void:
	_db = db
	_errors.clear()
	_warnings.clear()

	var fns  := _load_functions()
	var vars := _load_variables()
	var output_path: String = ProjectSettings.get_setting(
		"tarinoi/codegen/output_path", "res://bindings/generated/")
	if not output_path.ends_with("/"):
		output_path += "/"

	_validate_functions(fns, output_path)
	_validate_variables(vars, output_path)
	_flush_diagnostics()

	if _errors.is_empty() and _warnings.is_empty():
		print("Tarinoi codegen: bindings are up to date")


# ---------------------------------------------------------------------------
# Database loading
# ---------------------------------------------------------------------------

func _load_functions() -> Dictionary:
	# Returns { collection_name: String → Array of { name, args, returns, effect } }
	var rows := _db.query_rows("""
		SELECT d.payload, json_extract(c.payload, '$.collection_name') AS col_name
		FROM documents d
		JOIN collections c ON c.collection_id = d.collection_id
		WHERE d.document_type = 'function-declaration'
		  AND %s
		ORDER BY col_name, json_extract(d.payload, '$.identifier')
	""" % _db.active_filter())
	var result: Dictionary = {}
	for row: Dictionary in rows:
		var col := _str(row.get("col_name", ""))
		if col.is_empty():
			continue
		var payload: Variant = JSON.parse_string(_str(row.get("payload", "{}")))
		if not payload is Dictionary:
			continue
		if not result.has(col):
			result[col] = []
		(result[col] as Array).append({
			"name":    _str((payload as Dictionary).get("identifier", "")),
			"args":    (payload as Dictionary).get("function_args", []),
			"returns": _str((payload as Dictionary).get("function_returns", "")),
			"effect":  _str((payload as Dictionary).get("effect", "")),
		})
	return result


func _load_variables() -> Dictionary:
	# Returns { collection_name → Array of { name, data_type, default_value } }
	var rows := _db.query_rows("""
		SELECT d.payload, json_extract(c.payload, '$.collection_name') AS col_name
		FROM documents d
		JOIN collections c ON c.collection_id = d.collection_id
		WHERE d.document_type = 'variable-declaration'
		  AND %s
		ORDER BY col_name, json_extract(d.payload, '$.identifier')
	""" % _db.active_filter())
	var result: Dictionary = {}
	for row: Dictionary in rows:
		var col := _str(row.get("col_name", ""))
		if col.is_empty():
			continue
		var payload: Variant = JSON.parse_string(_str(row.get("payload", "{}")))
		if not payload is Dictionary:
			continue
		if not result.has(col):
			result[col] = []
		(result[col] as Array).append({
			"name":          _str((payload as Dictionary).get("identifier", "")),
			"data_type":     _str((payload as Dictionary).get("data_type", "")),
			"default_value": (payload as Dictionary).get("default_value", null),
		})
	return result


func _load_lists() -> Dictionary:
	# Returns { collection_name → Array of { identifier, options: Array of {key, option_value} } }
	var rows := _db.query_rows("""
		SELECT d.payload, json_extract(c.payload, '$.collection_name') AS col_name
		FROM documents d
		JOIN collections c ON c.collection_id = d.collection_id
		WHERE d.document_type = 'list-spec'
		  AND %s
		ORDER BY col_name, json_extract(d.payload, '$.identifier')
	""" % _db.active_filter())
	var result: Dictionary = {}
	for row: Dictionary in rows:
		var col := _str(row.get("col_name", ""))
		if col.is_empty():
			continue
		var payload: Variant = JSON.parse_string(_str(row.get("payload", "{}")))
		if not payload is Dictionary:
			continue
		if not result.has(col):
			result[col] = []
		(result[col] as Array).append({
			"identifier": _str((payload as Dictionary).get("identifier", "")),
			"options":   (payload as Dictionary).get("options", []),
		})
	return result


func _load_entities() -> Dictionary:
	# Returns { collection_name → Array of { identifier } }  (dialog_capable only)
	var rows := _db.query_rows("""
		SELECT d.payload, json_extract(c.payload, '$.collection_name') AS col_name
		FROM documents d
		JOIN collections c ON c.collection_id = d.collection_id
		WHERE d.document_type = 'entity'
		  AND json_extract(d.payload, '$.dialog_capable') = 1
		  AND %s
		ORDER BY col_name, json_extract(d.payload, '$.identifier')
	""" % _db.active_filter())
	var result: Dictionary = {}
	for row: Dictionary in rows:
		var col := _str(row.get("col_name", ""))
		if col.is_empty():
			continue
		var payload: Variant = JSON.parse_string(_str(row.get("payload", "{}")))
		if not payload is Dictionary:
			continue
		if not result.has(col):
			result[col] = []
		(result[col] as Array).append({
			"identifier": _str((payload as Dictionary).get("identifier", "")),
		})
	return result


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

func _validate_functions(fns: Dictionary, output_path: String) -> void:
	var path := output_path + "tarinoi_functions.gd"
	if not FileAccess.file_exists(ProjectSettings.globalize_path(path)):
		return

	var existing := _parse_classes_and_methods(path)
	var db_classes: Dictionary = {}
	for col: String in fns:
		var class_name_s := _to_pascal(col)
		db_classes[class_name_s] = {}
		for fn: Dictionary in (fns[col] as Array):
			db_classes[class_name_s][fn["name"]] = (fn["args"] as Array).size()

	# Missing from generated file (ERROR)
	for cls: String in db_classes:
		if not existing.has(cls):
			_errors.append("Missing function class '%s' in generated file — regenerate" % cls)
			continue
		for fn_name: String in (db_classes[cls] as Dictionary):
			if not (existing[cls] as Dictionary).has(fn_name):
				_errors.append("Missing function '%s.%s' in generated file — regenerate" % [cls, fn_name])
			else:
				var db_argc: int = (db_classes[cls] as Dictionary)[fn_name]
				var gen_argc: int = (existing[cls] as Dictionary)[fn_name]
				if db_argc != gen_argc:
					_errors.append("Arg count mismatch '%s.%s': DB=%d generated=%d — regenerate" % [cls, fn_name, db_argc, gen_argc])

	# In generated file but not in DB (WARNING)
	for cls: String in existing:
		if not db_classes.has(cls):
			_warnings.append("Obsolete function class '%s' in generated file — remove from impl" % cls)
			continue
		for fn_name: String in (existing[cls] as Dictionary):
			if not (db_classes[cls] as Dictionary).has(fn_name):
				_warnings.append("Obsolete function stub '%s.%s' — remove from impl" % [cls, fn_name])


func _validate_variables(vars: Dictionary, output_path: String) -> void:
	var path := output_path + "tarinoi_variables.gd"
	if not FileAccess.file_exists(ProjectSettings.globalize_path(path)):
		return

	var existing := _parse_classes_and_methods(path)
	for col: String in vars:
		var class_name_s := _to_pascal(col)
		if not existing.has(class_name_s):
			_errors.append("Missing variable class '%s' in generated file — regenerate" % class_name_s)

	for cls: String in existing:
		var found := false
		for col: String in vars:
			if _to_pascal(col) == cls:
				found = true
				break
		if not found:
			_warnings.append("Obsolete variable class '%s' in generated file — remove from impl" % cls)


# Parses a generated GDScript file for top-level classes and their func names + arg counts.
# Returns { class_name → { func_name → arg_count } }
func _parse_classes_and_methods(res_path: String) -> Dictionary:
	var abs_path := ProjectSettings.globalize_path(res_path)
	var file := FileAccess.open(abs_path, FileAccess.READ)
	if file == null:
		return {}
	var content := file.get_as_text()
	file.close()
	return parse_classes_from_content(content)


# Exposed for testing. Parses GDScript source text instead of a file.
func parse_classes_from_content(content: String) -> Dictionary:
	var result: Dictionary = {}
	var current_class := ""
	var class_re := RegEx.new()
	class_re.compile("^class (\\w+):")
	var func_re := RegEx.new()
	func_re.compile("^\\s+func (\\w+)\\(([^)]*)\\)")

	for line: String in content.split("\n"):
		var cm := class_re.search(line)
		if cm:
			current_class = cm.get_string(1)
			result[current_class] = {}
			continue
		if current_class.is_empty():
			continue
		var fm := func_re.search(line)
		if fm:
			var fn_name := fm.get_string(1)
			var args_str := fm.get_string(2).strip_edges()
			var argc := 0
			if not args_str.is_empty():
				argc = args_str.split(",").size()
			(result[current_class] as Dictionary)[fn_name] = argc

	return result


func _flush_diagnostics() -> void:
	for e: String in _errors:
		push_error("Tarinoi codegen: " + e)
	for w: String in _warnings:
		push_warning("Tarinoi codegen: " + w)


# ---------------------------------------------------------------------------
# Code generation
# ---------------------------------------------------------------------------

func _gen_functions(fns: Dictionary, header: String) -> String:
	if fns.is_empty():
		return header + "class_name TarinoiFunctions\n"
	var out := header + "class_name TarinoiFunctions\n"
	for col: String in _sorted_keys(fns):
		var class_name_s := _to_pascal(col)
		out += "\nclass %s:\n" % class_name_s
		for fn: Dictionary in (fns[col] as Array):
			var fn_name: String = fn["name"]
			var args: Array = fn["args"]
			var returns: String = fn["returns"]
			var effect: String = fn["effect"]
			var arg_names := _fn_arg_names(args)
			var arg_decls := _fn_arg_decls(args)
			out += "\t## %s(%s) -> %s\n" % [fn_name, arg_names, returns]
			if not effect.is_empty():
				out += "\t## effect: %s\n" % effect
			out += "\tfunc %s(%s) -> Variant:\n" % [fn_name, arg_decls]
			out += '\t\tpush_error("TarinoiFunctions.%s.%s is not implemented")\n' % [class_name_s, fn_name]
			out += "\t\treturn %s\n\n" % _default_return(returns)
	return out


func _gen_variables(vars: Dictionary, header: String) -> String:
	if vars.is_empty():
		return header + "class_name TarinoiVariables\n"
	var out := header + "class_name TarinoiVariables\n"
	for col: String in _sorted_keys(vars):
		var class_name_s := _to_pascal(col)
		out += "\nclass %s:\n" % class_name_s
		out += "\t## Variables in this collection:\n"
		for v: Dictionary in (vars[col] as Array):
			var default_str := str(v["default_value"]) if v["default_value"] != null else "null"
			out += "\t##   %s  (%s)  default: %s\n" % [v["name"], v["data_type"], default_str]
		out += "\n"
		out += "\tfunc get_variable(variable_name: String) -> Variant:\n"
		out += '\t\tpush_error("TarinoiVariables.%s.get_variable is not implemented")\n' % class_name_s
		out += "\t\treturn null\n\n"
		out += "\tfunc set_variable(variable_name: String, value: Variant) -> void:\n"
		out += '\t\tpush_error("TarinoiVariables.%s.set_variable is not implemented")\n\n' % class_name_s
	return out


func _gen_lists(lists: Dictionary, header: String) -> String:
	if lists.is_empty():
		return header + "class_name TarinoiLists\n"
	var out := header + "class_name TarinoiLists\n"
	for col: String in _sorted_keys(lists):
		out += "\nclass %s:\n" % _to_pascal(col)
		for lst: Dictionary in (lists[col] as Array):
			var list_id: String = lst["identifier"]
			var options: Array = lst["options"]
			out += "\tclass %s:\n" % _to_pascal(list_id)
			for opt: Variant in options:
				if not opt is Dictionary:
					continue
				var key: String = _str((opt as Dictionary).get("key", ""))
				if key.is_empty():
					continue
				out += '\t\tconst %s = "%s"\n' % [key.to_upper(), key]
			out += "\n"
	return out


func _gen_entities(ents: Dictionary, header: String) -> String:
	if ents.is_empty():
		return header + "class_name TarinoiEntities\n"
	var out := header + "class_name TarinoiEntities\n"
	for col: String in _sorted_keys(ents):
		out += "\nclass %s:\n" % _to_pascal(col)
		for ent: Dictionary in (ents[col] as Array):
			var entity_id: String = ent["identifier"]
			if entity_id.is_empty():
				continue
			out += '\tconst %s = "%s"\n' % [entity_id.to_upper(), entity_id]
		out += "\n"
	return out


# ---------------------------------------------------------------------------
# File I/O
# ---------------------------------------------------------------------------

func _write_file(res_path: String, content: String) -> void:
	var abs_path := ProjectSettings.globalize_path(res_path)
	var file := FileAccess.open(abs_path, FileAccess.WRITE)
	if file == null:
		push_error("Tarinoi codegen: failed to write '%s'" % abs_path)
		return
	file.store_string(content)
	file.close()


func _make_header() -> String:
	var repo_url: String = ProjectSettings.get_setting("tarinoi/git/repo_url", "")
	var commit: String = _db.read_meta("last_synced_commit")
	var ts := Time.get_datetime_string_from_system(false, true)
	return (
		"# AUTO-GENERATED by Tarinoi codegen.\n"
		+ "# Source: %s @ %s\n" % [repo_url, commit if not commit.is_empty() else "unknown"]
		+ "# Generated: %s\n" % ts
		+ "# Do not edit this file. Implement bindings in the impl/ directory.\n\n"
	)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

static func _to_pascal(s: String) -> String:
	var parts := s.split("_")
	var result := ""
	for p: String in parts:
		if not p.is_empty():
			result += p[0].to_upper() + p.substr(1)
	return result


static func _str(v: Variant) -> String:
	return str(v) if v != null else ""


static func _sorted_keys(d: Dictionary) -> Array:
	var keys := d.keys()
	keys.sort()
	return keys


func _fn_arg_names(args: Array) -> String:
	var names: Array[String] = []
	for a: Variant in args:
		if a is Dictionary:
			names.append(_str((a as Dictionary).get("arg_name", "")))
	return ", ".join(names)


func _fn_arg_decls(args: Array) -> String:
	var decls: Array[String] = []
	for a: Variant in args:
		if a is Dictionary:
			var name_s := _str((a as Dictionary).get("arg_name", ""))
			if not name_s.is_empty():
				decls.append(name_s + ": Variant")
	return ", ".join(decls)


static func _default_return(returns: String) -> String:
	match returns.to_lower():
		"boolean": return "false"
		"number":  return "0"
		"string":  return '""'
		"void":    return ""
		_:         return "null"
