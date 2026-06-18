class_name ExpressionParser

# Parses Tarinoi expression strings into AST Dictionaries.
#
# AST node shapes:
#   { "type": "and"|"or",       "left": node, "right": node }
#   { "type": "not",            "operand": node }
#   { "type": "bool_literal",   "value": bool }
#   { "type": "int_literal",    "value": int }
#   { "type": "float_literal",  "value": float }
#   { "type": "string_literal", "value": String }
#   { "type": "call",  "prefix": "Fn", "collection": String, "name": String, "args": Array }
#   { "type": "ref",   "prefix": "Var"|"Ent"|"Ls", "collection": String,
#                      "name": String, "key": String }  # key only meaningful for Ls


## Returns AST root, or null for empty/always-true. Logs error on parse failure.
static func parse_condition(expr: String) -> Variant:
	var s := expr.strip_edges()
	if s.is_empty():
		return null
	var p := _Parser.new()
	if not p.tokenize(s):
		return null
	var node: Variant = p.condition()
	if p.has_error or not p.at_end():
		TarinoiLogger.error("ExpressionParser: trailing tokens after condition in: %s" % s)
		return null
	return node


## Returns a single call AST node (for output_selector expressions). Empty dict on error.
static func parse_call(expr: String) -> Dictionary:
	var s := expr.strip_edges()
	if s.is_empty():
		return {}
	var p := _Parser.new()
	if not p.tokenize(s):
		return {}
	var node: Dictionary = p.call_expr()
	if p.has_error:
		return {}
	return node


# ---------------------------------------------------------------------------
# Inner parser — one instance per parse call; holds mutable cursor state.
# ---------------------------------------------------------------------------

class _Parser:
	# Each token: { "t": kind, "v": value }
	# kind: "IDENT" | "INT" | "FLOAT" | "STR" | "OP"
	var toks: Array = []
	var pos: int = 0
	var has_error: bool = false

	func at_end() -> bool:
		return pos >= toks.size()

	func _peek_type() -> String:
		if at_end():
			return "EOF"
		return toks[pos]["t"]

	func _peek_val() -> Variant:
		if at_end():
			return ""
		return toks[pos]["v"]

	func _consume() -> Dictionary:
		var t: Dictionary = toks[pos]
		pos += 1
		return t

	func _expect_op(op: String) -> bool:
		if _peek_type() == "OP" and _peek_val() == op:
			_consume()
			return true
		has_error = true
		TarinoiLogger.error("ExpressionParser: expected '%s', got '%s'" % [op, _peek_val()])
		return false

	func condition() -> Variant:
		return _or_expr()

	func _or_expr() -> Variant:
		var left: Variant = _and_expr()
		while _peek_type() == "OP" and _peek_val() == "||":
			_consume()
			var right: Variant = _and_expr()
			left = {"type": "or", "left": left, "right": right}
		return left

	func _and_expr() -> Variant:
		var left: Variant = _not_expr()
		while _peek_type() == "OP" and _peek_val() == "&&":
			_consume()
			var right: Variant = _not_expr()
			left = {"type": "and", "left": left, "right": right}
		return left

	func _not_expr() -> Variant:
		if _peek_type() == "OP" and _peek_val() == "!":
			_consume()
			return {"type": "not", "operand": _not_expr()}
		return _atom()

	func _atom() -> Variant:
		if _peek_type() == "IDENT":
			var v := _peek_val() as String
			if v == "true":
				_consume()
				return {"type": "bool_literal", "value": true}
			if v == "false":
				_consume()
				return {"type": "bool_literal", "value": false}
		if _peek_type() == "OP" and _peek_val() == "(":
			_consume()
			var inner: Variant = condition()
			_expect_op(")")
			return inner
		return _ref_or_call()

	func _ref_or_call() -> Variant:
		if _peek_type() != "IDENT":
			has_error = true
			TarinoiLogger.error("ExpressionParser: expected Fn/Var/Ent/Ls/Card identifier, got '%s'" % _peek_val())
			return {}
		var prefix := _consume()["v"] as String
		if prefix not in ["Fn", "Var", "Ent", "Ls", "Card"]:
			has_error = true
			TarinoiLogger.error("ExpressionParser: expected Fn/Var/Ent/Ls/Card prefix, got '%s'" % prefix)
			return {}
		_expect_op(".")

		if prefix == "Card":
			var name := ""
			if _peek_type() == "IDENT":
				name = _consume()["v"] as String
			return {"type": "card_ref", "name": name}

		var collection := ""
		if _peek_type() == "IDENT":
			collection = _consume()["v"] as String
		_expect_op(".")
		var name := ""
		if _peek_type() == "IDENT":
			name = _consume()["v"] as String

		if prefix == "Fn":
			_expect_op("(")
			var args: Array = _arg_list()
			_expect_op(")")
			return {"type": "call", "prefix": "Fn", "collection": collection, "name": name, "args": args}

		if prefix == "Ls":
			_expect_op(".")
			var key := ""
			if _peek_type() == "IDENT":
				key = _consume()["v"] as String
			return {"type": "ref", "prefix": "Ls", "collection": collection, "name": name, "key": key}

		# Var or Ent
		return {"type": "ref", "prefix": prefix, "collection": collection, "name": name, "key": ""}

	func call_expr() -> Dictionary:
		var node: Variant = _ref_or_call()
		if has_error or not (node is Dictionary) or node.get("type", "") != "call":
			has_error = true
			TarinoiLogger.error("ExpressionParser: expected a function call expression")
			return {}
		return node as Dictionary

	func _arg_list() -> Array:
		var args: Array = []
		if _peek_type() == "OP" and _peek_val() == ")":
			return args
		args.append(_arg())
		while _peek_type() == "OP" and _peek_val() == ",":
			_consume()
			args.append(_arg())
		return args

	func _arg() -> Variant:
		match _peek_type():
			"IDENT":
				var v := _peek_val() as String
				if v == "true":
					_consume()
					return {"type": "bool_literal", "value": true}
				if v == "false":
					_consume()
					return {"type": "bool_literal", "value": false}
				return _ref_or_call()
			"INT":
				return {"type": "int_literal", "value": _consume()["v"]}
			"FLOAT":
				return {"type": "float_literal", "value": _consume()["v"]}
			"STR":
				return {"type": "string_literal", "value": _consume()["v"]}
			_:
				has_error = true
				TarinoiLogger.error("ExpressionParser: unexpected token in argument: '%s'" % _peek_val())
				return {}

	func tokenize(expr: String) -> bool:
		toks = []
		var i := 0
		while i < expr.length():
			var c := expr[i]

			if c in [" ", "\t", "\n", "\r"]:
				i += 1
				continue

			# Two-char operators
			if i + 1 < expr.length():
				var two := expr.substr(i, 2)
				if two in ["&&", "||"]:
					toks.append({"t": "OP", "v": two})
					i += 2
					continue

			# Single-char operators
			if c in ["!", "(", ")", ",", "."]:
				toks.append({"t": "OP", "v": c})
				i += 1
				continue

			# String literal (double-quoted, no escape handling needed for Tarinoi)
			if c == '"':
				var j := i + 1
				while j < expr.length() and expr[j] != '"':
					j += 1
				toks.append({"t": "STR", "v": expr.substr(i + 1, j - i - 1)})
				i = j + 1
				continue

			# Number (integer or float; no negatives — use Var refs for signed values)
			if c >= "0" and c <= "9":
				var j := i
				while j < expr.length() and expr[j] >= "0" and expr[j] <= "9":
					j += 1
				# Check for decimal part
				if j < expr.length() and expr[j] == "." and j + 1 < expr.length() and expr[j + 1] >= "0" and expr[j + 1] <= "9":
					j += 1
					while j < expr.length() and expr[j] >= "0" and expr[j] <= "9":
						j += 1
					toks.append({"t": "FLOAT", "v": float(expr.substr(i, j - i))})
				else:
					toks.append({"t": "INT", "v": int(expr.substr(i, j - i))})
				i = j
				continue

			# Identifier: starts with letter or underscore
			if c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z"):
				var j := i
				while j < expr.length() and (
					expr[j] == "_" or
					(expr[j] >= "a" and expr[j] <= "z") or
					(expr[j] >= "A" and expr[j] <= "Z") or
					(expr[j] >= "0" and expr[j] <= "9")
				):
					j += 1
				toks.append({"t": "IDENT", "v": expr.substr(i, j - i)})
				i = j
				continue

			TarinoiLogger.error("ExpressionParser: unexpected character '%s' at position %d in: %s" % [c, i, expr])
			return false

		return true
