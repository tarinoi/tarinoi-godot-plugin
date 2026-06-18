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
	TarinoiRuntime.line_ready.connect(func(_d: Dictionary): _show_dialogue_mode())
	TarinoiRuntime.dialogue_ended.connect(_show_start_mode)
	TarinoiRuntime.dialogue_error.connect(func(m: String): push_error("Dialogue error: " + m))
	TarinoiRuntime.sync_failed.connect(func(r: String): push_error("Tarinoi sync failed: " + r))
	TarinoiRuntime.sync()
	_show_start_mode()


## Override this in a subclass to register your game's function and variable bindings.
## Called after configure() and before sync().
func _setup_bindings() -> void:
	pass


func _show_start_mode() -> void:
	_dialogue_strip.hide_strip()
	_choose_start.show()


func _show_dialogue_mode() -> void:
	_choose_start.hide()
