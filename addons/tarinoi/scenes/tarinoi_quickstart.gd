## Batteries-included quickstart scene.
## Combines TarinoiChooseStart and TarinoiDialogueStrip into a ready-to-run
## dialogue browser. Use "Tarinoi: Initialize project" to scaffold a copy
## into your project, then override _setup_bindings() to wire your game logic.
class_name TarinoiQuickStart
extends Control

@onready var _choose_start: TarinoiChooseStart     = $ChooseStart
@onready var _dialogue_strip: TarinoiDialogueStrip = $DialogueStrip


func _ready() -> void:
	TarinoiRuntime.configure()
	_setup_bindings()
	_bind_generated_defaults()
	TarinoiRuntime.line_ready.connect(func(_d: Dictionary): _show_dialogue_mode())
	TarinoiRuntime.dialogue_ended.connect(_show_start_mode)
	TarinoiRuntime.dialogue_error.connect(func(m: String): TarinoiLogger.error("dialogue error: " + m))
	TarinoiRuntime.sync_failed.connect(func(r: String): TarinoiLogger.error("sync failed: " + r))
	TarinoiRuntime.sync()
	_show_start_mode()


## Override this in a subclass to register your game's function and variable bindings.
## Called after configure() and before sync().
func _setup_bindings() -> void:
	pass


## Binds whatever the generated bindings can supply on their own, for any
## collection _setup_bindings() left unbound: the generated variable classes
## (TarinoiVariables.COLLECTIONS) and the scaffolded core functions
## (TarinoiCoreFunctions). That makes synced content that only uses
## Fn.tarinoi.* play with no code at all. A real game binds explicitly; this is
## a convenience of the quickstart scene, not of the runtime.
func _bind_generated_defaults() -> void:
	var registry: BindingRegistry = TarinoiRuntime.registry

	var variables := _global_class_script("TarinoiVariables")
	if variables != null:
		var collections: Variant = variables.get_script_constant_map().get("COLLECTIONS")
		if collections is Dictionary:
			for col: String in (collections as Dictionary):
				if registry.get_var_impl(col) == null:
					registry.bind_variable_collection(col, ((collections as Dictionary)[col] as GDScript).new())
					TarinoiLogger.debug("quickstart: bound generated variables for '%s'" % col)

	var core := _global_class_script("TarinoiCoreFunctions")
	if core != null and registry.get_fn_impl("tarinoi") == null:
		registry.bind_function_collection("tarinoi", core.new())
		TarinoiLogger.debug("quickstart: bound TarinoiCoreFunctions for 'tarinoi'")


## Loads a script registered under a global class_name; null if the project
## has none (bindings not generated yet).
static func _global_class_script(global_name: String) -> GDScript:
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if entry.get("class", "") == global_name:
			return load(entry["path"]) as GDScript
	return null


func _show_start_mode() -> void:
	_dialogue_strip.hide_strip()
	_choose_start.show()


func _show_dialogue_mode() -> void:
	_choose_start.hide()
