## Reusable interactable node for 2D scenes. Drop anywhere in a 2D scene tree.
## Set collection_id and card_id in the Inspector, then connect
## interaction_triggered to your controller to start dialogue.
## (2D counterpart to DialogueTrigger which extends Area3D.)
##
## Editor helper: while collection_id/card_id are empty, opening the scene in
## the editor prints all available start cards to the Output panel so you can
## copy the right UUID pair into the Inspector fields.
@tool
class_name DialogueTrigger2D
extends Area2D

## The Tarinoi collection (board) UUID that owns the start card.
@export var collection_id: String = ""
## The start card UUID within that collection.
@export var card_id: String = ""

## Emitted when activate() is called (typically by the player on key press).
signal interaction_triggered(collection_id: String, card_id: String)


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		return
	await DialogueTriggerHelper.describe_in_editor(
		"DialogueTrigger2D '%s'" % name, collection_id, card_id
	)


## Call this from your player script when the interact key is pressed while
## the player is overlapping this area.
func activate() -> void:
	if collection_id.is_empty() or card_id.is_empty():
		push_warning("DialogueTrigger2D '%s': collection_id or card_id not set." % name)
		return
	interaction_triggered.emit(collection_id, card_id)
