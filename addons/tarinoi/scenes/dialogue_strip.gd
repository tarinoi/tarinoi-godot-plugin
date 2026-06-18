## Scrolling dialogue feed UI. Drop this scene into any Control hierarchy.
## Auto-connects to TarinoiRuntime signals for line_ready, choices_ready,
## and pin_choice_needed. The parent scene is responsible for calling
## hide_strip() when dialogue_ended fires.
class_name TarinoiDialogueStrip
extends Control

@onready var feed_vbox: VBoxContainer     = $Background/Margin/FeedScroll/FeedVBox
@onready var feed_scroll: ScrollContainer = $Background/Margin/FeedScroll
@onready var advance_hint: Label          = $AdvanceHint

const DIM_MODULATE  := Color(0.55, 0.55, 0.6, 0.75)
const LIVE_MODULATE := Color(1.0, 1.0, 1.0, 1.0)

var _choice_count: int = 0
var _active_choice_entry: VBoxContainer = null
var _active_choice_texts: Array = []


func _ready() -> void:
	feed_scroll.get_v_scroll_bar().changed.connect(func():
		feed_scroll.scroll_vertical = feed_scroll.get_v_scroll_bar().max_value
	)
	TarinoiRuntime.line_ready.connect(show_line)
	TarinoiRuntime.choices_ready.connect(show_choices)
	TarinoiRuntime.pin_choice_needed.connect(show_pins)


func show_line(line_data: Dictionary) -> void:
	_choice_count = 0
	_active_choice_entry = null
	_finalize_and_dim_all()
	var entry: VBoxContainer
	if line_data.get("line_mode", "") == "system":
		entry = _make_system_entry(line_data.get("line", ""))
	else:
		entry = _make_line_entry(
			line_data.get("entity_label", ""),
			line_data.get("line", "")
		)
	entry.modulate = LIVE_MODULATE
	feed_vbox.add_child(entry)
	advance_hint.show()
	show()


func show_choices(choices: Array) -> void:
	_finalize_and_dim_all()
	_active_choice_texts = choices.map(func(c: Dictionary) -> String: return c.get("line", "…"))
	_choice_count = choices.size()

	var entry := VBoxContainer.new()
	entry.modulate = LIVE_MODULATE
	for i in choices.size():
		var btn := Button.new()
		btn.text = "%d. %s" % [i + 1, _active_choice_texts[i]]
		btn.size_flags_horizontal = SIZE_EXPAND_FILL
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		if choices[i].get("visited", false):
			btn.modulate = Color(1, 1, 1, 0.45)
		var idx := i
		btn.pressed.connect(func(): _select_choice(entry, idx))
		entry.add_child(btn)

	_active_choice_entry = entry
	feed_vbox.add_child(entry)
	advance_hint.hide()
	show()


## Dev tooling: named pin selection.
func show_pins(pin_names: Array) -> void:
	_finalize_and_dim_all()
	var entry := VBoxContainer.new()
	entry.modulate = LIVE_MODULATE
	var header := Label.new()
	header.text = "[dev] choose pin"
	header.add_theme_color_override("font_color", Color(0.8, 0.6, 0.2))
	entry.add_child(header)
	for pin_name in pin_names:
		var btn := Button.new()
		btn.text = pin_name as String
		btn.size_flags_horizontal = SIZE_EXPAND_FILL
		var pn := pin_name as String
		btn.pressed.connect(func(): TarinoiRuntime.select_pin(pn))
		entry.add_child(btn)
	feed_vbox.add_child(entry)
	advance_hint.hide()
	show()


## Clear the feed and hide the strip. Call this from your scene on dialogue_ended.
func hide_strip() -> void:
	_choice_count = 0
	_active_choice_entry = null
	for child in feed_vbox.get_children():
		child.queue_free()
	advance_hint.hide()
	hide()


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _make_system_entry(text: String) -> VBoxContainer:
	var entry := VBoxContainer.new()
	var lbl := Label.new()
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.8, 0.4))
	entry.add_child(lbl)
	return entry


func _make_line_entry(speaker: String, line: String) -> VBoxContainer:
	var entry := VBoxContainer.new()
	if not speaker.is_empty():
		var sp := Label.new()
		sp.text = speaker
		sp.add_theme_font_size_override("font_size", 12)
		sp.add_theme_color_override("font_color", Color(0.65, 0.72, 1.0))
		entry.add_child(sp)
	var txt := Label.new()
	txt.text = line
	txt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	txt.size_flags_horizontal = SIZE_EXPAND_FILL
	txt.add_theme_font_size_override("font_size", 14)
	entry.add_child(txt)
	return entry


func _finalize_and_dim_all() -> void:
	for entry in feed_vbox.get_children():
		_freeze_buttons(entry)
		entry.modulate = DIM_MODULATE


func _freeze_buttons(entry: Control) -> void:
	for child in entry.get_children():
		if child is Button:
			var lbl := Label.new()
			lbl.text = child.text
			lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			lbl.size_flags_horizontal = SIZE_EXPAND_FILL
			lbl.add_theme_font_size_override("font_size", 14)
			child.replace_by(lbl)
			child.queue_free()


func _select_choice(entry: VBoxContainer, idx: int) -> void:
	var text: String = _active_choice_texts[idx]
	_choice_count = 0
	_active_choice_entry = null
	_collapse_to_label(entry, text)
	TarinoiRuntime.select_choice(idx)


func _collapse_to_label(entry: VBoxContainer, chosen_text: String) -> void:
	for child in entry.get_children():
		child.queue_free()
	var lbl := Label.new()
	lbl.text = chosen_text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", 14)
	entry.add_child(lbl)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_accept"):
		if TarinoiRuntime.get_state() == "NPC_LINE":
			TarinoiRuntime.advance()
			get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		var idx: int = event.keycode - KEY_1
		if idx >= 0 and idx < _choice_count and _active_choice_entry != null:
			_select_choice(_active_choice_entry, idx)
			get_viewport().set_input_as_handled()
