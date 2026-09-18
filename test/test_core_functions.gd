extends GutTest

# The core functions scaffold: what codegen renders for Fn.tarinoi.*, and — by
# loading the rendered source and calling it — that the reference bodies behave
# as in-app playback does. The behavioural cases follow CoreFunctions.spec.js
# in the Tarinoi app.

const TMP_DIR := "user://test_core_functions/"
const BASE_PATH := TMP_DIR + "tarinoi_functions.gd"
const SCAFFOLD_PATH := TMP_DIR + "tarinoi_core_functions.gd"


## Stand-in for a generated variables class: a plain dictionary store where an
## unset variable reads as null, which is what the defaults are about.
class FakeVariables:
	var values: Dictionary = {}

	func get_variable(variable_name: String) -> Variant:
		return values.get(variable_name)

	func set_variable(variable_name: String, value: Variant) -> void:
		values[variable_name] = value


var _cg: TarinoiCodegen
var _vars: FakeVariables
var _core: Object  # instance of the loaded scaffold


static func _decl(fn_name: String, arg_names: Array, returns: String = "void") -> Dictionary:
	var args: Array = []
	for n: String in arg_names:
		args.append({"arg_name": n})
	return {"name": fn_name, "args": args, "returns": returns, "effect": ""}


## The thirteen declarations, as codegen loads them from a synced project.
static func _core_decls() -> Array:
	var decls: Array = []
	for fn_name: String in TarinoiCoreFunctionsScaffold.FUNCTIONS:
		var spec: Dictionary = TarinoiCoreFunctionsScaffold.FUNCTIONS[fn_name]
		var returns := "boolean" if fn_name.begins_with("Number") or fn_name.begins_with("String") or fn_name == "FlagIsSet" else "void"
		decls.append(_decl(fn_name, spec["args"], returns))
	return decls


func _ref(var_name: String) -> VarRef:
	return VarRef.new(_vars, "global", var_name)


func before_all() -> void:
	# Render the generated base class and the scaffold to disk once, then load
	# the scaffold as a real script, so every call below runs generated code.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))
	var cg := TarinoiCodegen.new()
	var base := cg._gen_functions({TarinoiCoreFunctionsScaffold.COLLECTION: _core_decls()}, "")
	base = base.replace("class_name TarinoiFunctions\n", "")
	_write(BASE_PATH, base)
	var rendered := TarinoiCoreFunctionsScaffold.render(_core_decls(), "test", {
		"base": '"%s".TarinoiTarinoiFunctions' % BASE_PATH,
		"class_name": "",
	})
	_write(SCAFFOLD_PATH, rendered["source"])


func after_all() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCAFFOLD_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(BASE_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_DIR))


func before_each() -> void:
	_cg = TarinoiCodegen.new()
	_vars = FakeVariables.new()
	var script := load(SCAFFOLD_PATH) as GDScript
	assert_not_null(script, "scaffold loads as a script")
	_core = script.new()


static func _write(path: String, content: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(content)
	f.close()


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func test_render_stamps_version_on_the_first_line() -> void:
	var out: String = TarinoiCoreFunctionsScaffold.render(_core_decls(), "test")["source"]
	assert_true(out.begins_with(TarinoiCoreFunctionsScaffold.STAMP_PREFIX + TarinoiCoreFunctionsScaffold.VERSION))
	assert_eq(TarinoiCoreFunctionsScaffold.stamp_version(out), TarinoiCoreFunctionsScaffold.VERSION)


func test_render_declares_the_global_class_over_the_generated_base() -> void:
	var out: String = TarinoiCoreFunctionsScaffold.render(_core_decls(), "test")["source"]
	assert_true(out.contains("\nclass_name TarinoiCoreFunctions\n"))
	assert_true(out.contains("\nextends TarinoiFunctions.TarinoiTarinoiFunctions\n"))


func test_render_covers_every_core_function_in_author_order() -> void:
	var rendered := TarinoiCoreFunctionsScaffold.render(_core_decls(), "test")
	assert_eq((rendered["unknown"] as Array).size(), 0, "all thirteen are known")
	var out: String = rendered["source"]
	var last := -1
	for fn_name: String in TarinoiCoreFunctionsScaffold.ORDER:
		var pos := out.find("\nfunc %s(" % fn_name)
		assert_gt(pos, last, "%s follows its predecessor in ORDER" % fn_name)
		last = pos


func test_render_stubs_a_function_the_plugin_does_not_know() -> void:
	var decls := _core_decls()
	decls.append(_decl("ResetEverything", [], "void"))
	var rendered := TarinoiCoreFunctionsScaffold.render(decls, "test")
	assert_eq(rendered["unknown"], ["ResetEverything"])
	assert_true((rendered["source"] as String).contains('push_error("TarinoiCoreFunctions.ResetEverything is not implemented")'))


func test_render_stubs_a_known_name_with_the_wrong_arity() -> void:
	var decls := _core_decls().filter(func(d: Dictionary) -> bool: return d["name"] != "SetFlag")
	decls.append(_decl("SetFlag", ["flagRef", "value"], "void"))
	var rendered := TarinoiCoreFunctionsScaffold.render(decls, "test")
	assert_eq(rendered["unknown"], ["SetFlag"])
	assert_true((rendered["source"] as String).contains("func SetFlag(flagRef: Variant, value: Variant) -> Variant:"))
	assert_false((rendered["source"] as String).contains("_write(flagRef, true)"))


func test_stamp_version_is_empty_without_a_stamp() -> void:
	assert_eq(TarinoiCoreFunctionsScaffold.stamp_version("# something else\nclass_name X"), "")
	assert_eq(TarinoiCoreFunctionsScaffold.stamp_version(""), "")


func test_parse_methods_from_content_counts_top_level_funcs() -> void:
	var out: String = TarinoiCoreFunctionsScaffold.render(_core_decls(), "test")["source"]
	var methods := TarinoiCodegen.parse_methods_from_content(out)
	assert_eq(methods.get("SetFlag"), 1)
	assert_eq(methods.get("NumberAtLeast"), 2)
	assert_eq(methods.size(), 13 + 4, "thirteen functions plus the four helpers")


# ---------------------------------------------------------------------------
# Flags — "sets, clears and toggles, treating an unset flag as clear"
# ---------------------------------------------------------------------------

func test_flag_is_set_reads_unset_as_false() -> void:
	assert_eq(_core.FlagIsSet(_ref("met")), false)


func test_set_and_clear_flag() -> void:
	_core.SetFlag(_ref("met"))
	assert_eq(_vars.values["met"], true)
	assert_eq(_core.FlagIsSet(_ref("met")), true)
	_core.ClearFlag(_ref("met"))
	assert_eq(_vars.values["met"], false)
	assert_eq(_core.FlagIsSet(_ref("met")), false)


func test_toggle_flag_sets_an_unset_flag_then_clears_it() -> void:
	_core.ToggleFlag(_ref("met"))
	assert_eq(_vars.values["met"], true)
	_core.ToggleFlag(_ref("met"))
	assert_eq(_vars.values["met"], false)


func test_mutator_without_a_reference_logs_and_does_nothing() -> void:
	_core.SetFlag(true)
	assert_push_error_count(1)
	assert_true(_vars.values.is_empty())


# ---------------------------------------------------------------------------
# Counters and text — "increments from 0 when unset, and by a negative delta";
# "takes a value from a literal, a variable, or a list item"
# ---------------------------------------------------------------------------

func test_increment_counter_starts_from_zero_and_takes_negative_deltas() -> void:
	_core.IncrementCounter(_ref("morale"), 1)
	assert_eq(_vars.values["morale"], 1.0)
	_core.IncrementCounter(_ref("morale"), -3)
	assert_eq(_vars.values["morale"], -2.0)


func test_set_counter_from_a_literal_a_variable_and_a_list_item() -> void:
	_core.SetCounter(_ref("morale"), 5)
	assert_eq(_vars.values["morale"], 5.0)
	_vars.values["starting"] = 7.0
	_core.SetCounter(_ref("morale"), _ref("starting"))
	assert_eq(_vars.values["morale"], 7.0)
	# A list item reaches the function already resolved to its option value.
	_core.SetCounter(_ref("morale"), 2.5)
	assert_eq(_vars.values["morale"], 2.5)


func test_set_text_from_a_literal_and_a_variable() -> void:
	_core.SetText(_ref("title"), "Ferry Captain")
	assert_eq(_vars.values["title"], "Ferry Captain")
	_vars.values["rank"] = "Admiral"
	_core.SetText(_ref("title"), _ref("rank"))
	assert_eq(_vars.values["title"], "Admiral")


func test_value_of_the_wrong_type_logs_and_uses_the_default() -> void:
	# Playback rejects these outright; the game logs and carries on with the
	# type's default rather than crash mid-dialogue.
	_core.SetCounter(_ref("morale"), "lots")
	assert_eq(_vars.values["morale"], 0.0)
	_core.SetText(_ref("title"), 42)
	assert_eq(_vars.values["title"], "")
	_vars.values["flag"] = "yes"
	assert_eq(_core.FlagIsSet(_ref("flag")), false)
	assert_push_error_count(3)


# ---------------------------------------------------------------------------
# Comparisons — "treats unset counters as 0 and unset text as empty";
# "compares any mix of literals, variables and list items"
# ---------------------------------------------------------------------------

func test_unset_counter_compares_as_zero() -> void:
	assert_true(_core.NumberEquals(_ref("nothing"), 0))
	assert_true(_core.NumberAtMost(_ref("nothing"), 0))
	assert_false(_core.NumberGreaterThan(_ref("nothing"), 0))


func test_unset_text_compares_as_empty() -> void:
	assert_true(_core.StringEquals(_ref("nothing"), ""))
	assert_false(_core.StringEquals(_ref("nothing"), "x"))


func test_numeric_comparators_over_a_mix_of_sources() -> void:
	_vars.values["strength"] = 12.0
	_vars.values["hard"] = 12.0
	assert_true(_core.NumberAtLeast(_ref("strength"), _ref("hard")))
	assert_true(_core.NumberAtLeast(_ref("strength"), 12))
	assert_false(_core.NumberGreaterThan(_ref("strength"), 12.0))
	assert_true(_core.NumberGreaterThan(13, _ref("strength")))
	assert_true(_core.NumberAtMost(_ref("strength"), 12))
	assert_true(_core.NumberLessThan(11.5, _ref("strength")))
	assert_false(_core.NumberLessThan(_ref("strength"), _ref("hard")))
	assert_true(_core.NumberEquals(1, 1.0), "int and float literals compare as numbers")


func test_string_equals_over_a_mix_of_sources() -> void:
	_vars.values["faction"] = "rebels"
	assert_true(_core.StringEquals(_ref("faction"), "rebels"))
	assert_true(_core.StringEquals("rebels", _ref("faction")))
	assert_false(_core.StringEquals(_ref("faction"), "empire"))


func test_mismatched_operand_types_log_rather_than_coerce() -> void:
	# "rejects mismatched operand types rather than coercing": "1" is not 1.
	assert_false(_core.NumberEquals("1", 1))
	assert_push_error_count(1)


# ---------------------------------------------------------------------------
# Codegen integration: scaffold once, validate afterwards
# ---------------------------------------------------------------------------

const IMPL_DIR := TMP_DIR + "impl/"


func _fns_with_core() -> Dictionary:
	return {TarinoiCoreFunctionsScaffold.COLLECTION: _core_decls(), "global": [_decl("Mine", [], "void")]}


func _scaffold_file() -> String:
	return IMPL_DIR + TarinoiCoreFunctionsScaffold.FILE_NAME


func _remove_scaffold() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_scaffold_file()))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(IMPL_DIR))


func _open_codegen_db() -> TarinoiDB:
	var db := TarinoiDB.new()
	assert_true(db.open("__test_core_functions__"), "DB opened for test")
	_cg._db = db
	return db


func test_scaffold_is_written_once_and_never_overwritten() -> void:
	_remove_scaffold()
	var db := _open_codegen_db()
	_cg._scaffold_core_functions(_fns_with_core(), IMPL_DIR)
	assert_true(FileAccess.file_exists(_scaffold_file()), "scaffold written")
	_write(_scaffold_file(), "# my edits\n")
	_cg._scaffold_core_functions(_fns_with_core(), IMPL_DIR)
	assert_eq(FileAccess.get_file_as_string(_scaffold_file()), "# my edits\n", "the game's file is left alone")
	db.close()
	_remove_scaffold()


func test_no_scaffold_without_the_tarinoi_collection() -> void:
	_remove_scaffold()
	var db := _open_codegen_db()
	_cg._scaffold_core_functions({"global": [_decl("Mine", [], "void")]}, IMPL_DIR)
	assert_false(FileAccess.file_exists(_scaffold_file()))
	db.close()


func test_validate_is_quiet_for_a_fresh_scaffold() -> void:
	_remove_scaffold()
	var db := _open_codegen_db()
	_cg._scaffold_core_functions(_fns_with_core(), IMPL_DIR)
	_cg._validate_core_functions(_fns_with_core(), IMPL_DIR)
	assert_eq(_cg._warnings.size(), 0, str(_cg._warnings))
	db.close()
	_remove_scaffold()


func test_validate_warns_when_the_collection_is_gone() -> void:
	_remove_scaffold()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(IMPL_DIR))
	_write(_scaffold_file(), TarinoiCoreFunctionsScaffold.render(_core_decls(), "test")["source"])
	_cg._validate_core_functions({"global": []}, IMPL_DIR)
	assert_eq(_cg._warnings.size(), 1)
	assert_true((_cg._warnings[0] as String).contains("no 'tarinoi' collection"))
	_remove_scaffold()


func test_validate_warns_on_an_older_stamp_and_a_missing_function() -> void:
	_remove_scaffold()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(IMPL_DIR))
	var source: String = TarinoiCoreFunctionsScaffold.render(_core_decls(), "test")["source"]
	source = source.replace(TarinoiCoreFunctionsScaffold.STAMP_PREFIX + TarinoiCoreFunctionsScaffold.VERSION, TarinoiCoreFunctionsScaffold.STAMP_PREFIX + "0.0.0")
	_write(_scaffold_file(), source)
	var fns := _fns_with_core()
	(fns[TarinoiCoreFunctionsScaffold.COLLECTION] as Array).append(_decl("Newer", [], "void"))
	_cg._validate_core_functions(fns, IMPL_DIR)
	assert_eq(_cg._warnings.size(), 2, str(_cg._warnings))
	assert_true((_cg._warnings[0] as String).contains("version '0.0.0'"))
	assert_true((_cg._warnings[1] as String).contains("has no 'Newer'"))
	_remove_scaffold()
