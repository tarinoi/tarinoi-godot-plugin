## Shared editor helper for DialogueTrigger and DialogueTrigger2D.
## Not intended for direct use outside those two nodes.
class_name DialogueTriggerHelper


## In @tool context, lists available start cards to the Output panel when the
## trigger has no target set, or prints the current target when one is set.
## TarinoiRuntime is available as a singleton accessor in editor @tool scripts.
static func describe_in_editor(trigger_name: String, collection_id: String, card_id: String) -> void:
	if not collection_id.is_empty() and not card_id.is_empty():
		print("%s: targeting %s / %s" % [trigger_name, collection_id, card_id])
		return
	if not Engine.has_singleton("TarinoiRuntime"):
		print("%s: TarinoiRuntime not available in editor. Run sync first." % trigger_name)
		return
	var runtime: Node = Engine.get_singleton("TarinoiRuntime")
	var cards: Array = await runtime.get_start_cards()
	if cards.is_empty():
		print("%s: no start cards found — run Tarinoi > Sync first." % trigger_name)
		return
	print("%s: available start cards —" % trigger_name)
	for c in cards:
		var label: String = c.get("label", "")
		if label.is_empty():
			label = "(no label)"
		print("  collection_id = \"%s\"   card_id = \"%s\"   [%s / %s]" % [
			c["collection_id"], c["card_id"], c["collection_label"], label
		])
