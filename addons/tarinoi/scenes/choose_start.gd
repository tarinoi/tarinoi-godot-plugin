## Generic start-card picker. Drop this scene into any Control hierarchy.
## Auto-populates from TarinoiRuntime once sync completes.
## Clicking a start card calls TarinoiRuntime.start_dialogue() and emits start_selected.
class_name TarinoiChooseStart
extends Control

@onready var _status: Label          = $Margin/VBox/SyncStatus
@onready var _button_vbox: VBoxContainer = $Margin/VBox/Scroll/ButtonVBox

## Emitted when the player selects a start card (after start_dialogue is called).
signal start_selected(collection_id: String, card_id: String)


func _ready() -> void:
	TarinoiRuntime.sync_completed.connect(func(_s: Dictionary):
		if visible:
			_populate()
	)
	TarinoiRuntime.sync_failed.connect(func(r: String):
		_status.text = "Sync failed: " + r
	)
	var initial: Array = await TarinoiRuntime.get_start_cards()
	if initial.is_empty():
		_status.text = "Syncing Tarinoi content…"
	else:
		_populate()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and visible and is_node_ready():
		if TarinoiRuntime.get_state() != "IDLE":
			hide()
			return
		_populate()


func _populate() -> void:
	var cards: Array = await TarinoiRuntime.get_start_cards()
	for child in _button_vbox.get_children():
		child.queue_free()

	if cards.is_empty():
		_status.text = "No start cards found. Check Tarinoi settings and run Sync."
		return

	_status.text = ""
	var current_collection := ""
	for item in cards:
		if item["collection_label"] != current_collection:
			current_collection = item["collection_label"]
			var header := Label.new()
			header.text = current_collection
			header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			header.add_theme_color_override("font_color", Color(0.6, 0.6, 0.8))
			_button_vbox.add_child(header)

		var btn := Button.new()
		var label: String = item.get("label", "")
		btn.text = label if not label.is_empty() else "(unlabelled start)"
		btn.size_flags_horizontal = SIZE_EXPAND_FILL
		var col_id: String = item["collection_id"]
		var card_id: String = item["card_id"]
		btn.pressed.connect(func(): _on_card_selected(col_id, card_id))
		_button_vbox.add_child(btn)


func _on_card_selected(col_id: String, card_id: String) -> void:
	start_selected.emit(col_id, card_id)
	TarinoiRuntime.start_dialogue(col_id, card_id)
