class_name Dispatcher

var _registry: BindingRegistry
var _lists: Dictionary = {}        # "collection_name/list_identifier" → Array of option dicts
var _cache: Dictionary = {}        # expr_string → AST (condition) or "__call__"+expr → AST (call)
var _context_card: Dictionary = {} # current card being processed — resolved by Card.CurrentContextCard


func _init(registry: BindingRegistry) -> void:
	_registry = registry


## Replace the in-memory list data.  Called by TarinoiRuntime after every
## configure() and sync so that Ls.* expressions always see current data.
func set_lists(lists: Dictionary) -> void:
	_lists = lists


## Set the card that Card.CurrentContextCard resolves to.
## Called by TarinoiRuntime at the start of _follow_connections.
func set_context_card(card: Dictionary) -> void:
	_context_card = card


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Evaluates a boolean condition expression string. Empty string → true.
func eval_condition(expr: String) -> bool:
	if expr.is_empty():
		return true
	var ast: Variant = _get_condition_ast(expr)
	if ast == null:
		return true  # parse error already logged; treat as pass
	return _truthy(_eval_node(ast))


## Evaluates a single function-call expression string. Returns Variant result.
func eval_call(expr: String) -> Variant:
	if expr.is_empty():
		return ""
	var ast: Dictionary = _get_call_ast(expr)
	if ast.is_empty():
		return ""
	return _eval_node(ast)


## Evaluates any expression string, returning the raw Variant (not coerced to bool).
func eval_value(expr: String) -> Variant:
	if expr.is_empty():
		return null
	var ast: Variant = _get_condition_ast(expr)
	if ast == null:
		return null
	return _eval_node(ast)


## Returns true if the function named in a call expression is bound and callable.
## Used to check before eval_call so callers can fall back gracefully.
func has_call(expr: String) -> bool:
	var ast: Dictionary = _get_call_ast(expr)
	if ast.is_empty():
		return false
	var impl: Object = _registry.get_fn_impl(ast.get("collection", "") as String)
	return impl != null and impl.has_method(ast.get("name", "") as String)


# ---------------------------------------------------------------------------
# AST cache
# ---------------------------------------------------------------------------

func _get_condition_ast(expr: String) -> Variant:
	if _cache.has(expr):
		return _cache[expr]
	var ast: Variant = ExpressionParser.parse_condition(expr)
	_cache[expr] = ast
	return ast


func _get_call_ast(expr: String) -> Dictionary:
	var key := "__call__" + expr
	if _cache.has(key):
		return _cache[key] as Dictionary
	var ast: Dictionary = ExpressionParser.parse_call(expr)
	_cache[key] = ast
	return ast


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

## Coerces an evaluated value to a boolean.
##
## Var.* references resolve to a VarRef object rather than a value, so that
## functions receiving one can write through it. A bare VarRef reaching a
## boolean context must therefore be read first: plain bool() is true for any
## non-null Object, which silently made conditions like "Var.global.some_flag"
## always pass regardless of what the variable held.
## null is handled before bool(), which has no null constructor and would raise
## "Nonexistent 'bool' constructor" instead. Unresolved references and unbound
## collections both evaluate to null, so this path is reached in ordinary use.
static func _truthy(value: Variant) -> bool:
	var resolved: Variant = VarRef.resolve(value)
	if resolved == null:
		return false
	return bool(resolved)


func _eval_node(node: Variant) -> Variant:
	if node == null:
		return true
	if not node is Dictionary:
		return true
	var t := (node as Dictionary).get("type", "") as String
	match t:
		"bool_literal":
			return node["value"]
		"int_literal":
			return node["value"]
		"float_literal":
			return node["value"]
		"string_literal":
			return node["value"]
		"not":
			return not _truthy(_eval_node(node["operand"]))
		"and":
			var left: Variant = _eval_node(node["left"])
			if not _truthy(left):
				return false
			return _truthy(_eval_node(node["right"]))
		"or":
			var left: Variant = _eval_node(node["left"])
			if _truthy(left):
				return true
			return _truthy(_eval_node(node["right"]))
		"call":
			return _dispatch_fn(node as Dictionary)
		"ref":
			return _resolve_ref(node as Dictionary)
		"card_ref":
			return _context_card
		_:
			TarinoiLogger.error("Dispatcher: unknown AST node type '%s'" % t)
			return false


func _dispatch_fn(node: Dictionary) -> Variant:
	var collection := node["collection"] as String
	var name := node["name"] as String
	var impl: Object = _registry.get_fn_impl(collection)
	if impl == null:
		TarinoiLogger.error("Dispatcher: unbound function collection '%s'" % collection)
		return false
	if not impl.has_method(name):
		TarinoiLogger.error("Dispatcher: function not found '%s.%s'" % [collection, name])
		return false
	var resolved_args: Array = []
	for arg: Variant in (node["args"] as Array):
		resolved_args.append(_eval_node(arg))
	TarinoiLogger.debug("→ Fn.%s.%s(%s)" % [collection, name, _fmt_args(resolved_args)])
	var result: Variant = impl.callv(name, resolved_args)
	TarinoiLogger.debug("  ← %s" % str(result))
	return result


static func _fmt_args(args: Array) -> String:
	return ", ".join(args.map(func(a: Variant) -> String: return str(a)))


func _resolve_ref(node: Dictionary) -> Variant:
	var prefix := node.get("prefix", "") as String
	var collection := node.get("collection", "") as String
	var name := node.get("name", "") as String
	match prefix:
		"Var":
			var impl: Object = _registry.get_var_impl(collection)
			if impl == null:
				TarinoiLogger.error("Dispatcher: unbound variable collection '%s'" % collection)
				return null
			TarinoiLogger.debug("Var.%s.%s resolved" % [collection, name])
			return VarRef.new(impl, collection, name)
		"Ent":
			var impl: Object = _registry.get_ent_impl(collection)
			if impl == null:
				TarinoiLogger.error("Dispatcher: unbound entity collection '%s'" % collection)
				return null
			return impl.get_entity(name)
		"Ls":
			return _resolve_list(collection, name, node.get("key", "") as String)
		_:
			TarinoiLogger.error("Dispatcher: unknown ref prefix '%s'" % prefix)
			return null


func _resolve_list(collection_name: String, list_name: String, key: String) -> Variant:
	var list_key := collection_name + "/" + list_name
	if not _lists.has(list_key):
		TarinoiLogger.warn("Dispatcher: list not found '%s.%s'" % [collection_name, list_name])
		return null
	for opt: Variant in (_lists[list_key] as Array):
		if opt is Dictionary and (opt as Dictionary).get("key", "") == key:
			var d := opt as Dictionary
			return d.get("option_value", d.get("value", null))
	TarinoiLogger.warn("Dispatcher: list option not found '%s.%s.%s'" % [collection_name, list_name, key])
	return null
