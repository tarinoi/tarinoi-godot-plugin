# Expression Parser and Binding Layer

## Responsibility

Parse Tarinoi expression strings into callable invocations, maintain a
registry of game-provided implementation objects, and dispatch parsed
expressions to the correct implementation at runtime.

The expression format is an internal Tarinoi detail. Game developers never
see `Fn.`, `Var.`, `Ent.`, or `Ls.` prefixes. They implement and bind named
GDScript objects; the plugin handles resolution.

---

## Expression Format

Tarinoi expressions appear in:
- `payload.input_pin.condition` — a boolean expression gating card entry
- `payload.switch` — a single function call returning a String (pin name)
- card template props with `sub_type: "function-call"` or `"condition"`

### Reference Types

| Prefix | Meaning | Example |
|---|---|---|
| `Fn` | Function call | `Fn.checks.SkillCheck(arg1, arg2)` |
| `Var` | Variable reference (as argument) | `Var.player.health` |
| `Ent` | Entity reference (as argument) | `Ent.major.sylvia_whistler` |
| `Ls` | List value reference | `Ls.player.skills.mechanics` |

Resolution path after prefix:
- `Fn.<collection_name>.<function_name>(<args>)`
- `Var.<collection_name>.<variable_name>`
- `Ent.<collection_name>.<entity_name>`
- `Ls.<collection_name>.<list_name>.<option_key>`

`collection_name` matches `payload.collection_name` on the corresponding
collection manifest in the `collections` table.

### Condition Grammar

Conditions are boolean expressions composed of:
- Function calls: `Fn.collection.Function(args)`
- Logical operators: `&&`, `||`
- Grouping: `(`, `)`
- Negation: `!`
- Boolean literals: `true`, `false`

Empty string condition is always-true.

Example:
```
(Fn.global.MyFunnyGate(true) && Fn.global.MyFunnyGate(false))
```

### Argument Types

Function call arguments may be:
- Boolean literals: `true`, `false`
- Integer literals: `42`
- Float literals: `3.14`
- String literals: `"hello"`
- Variable references: `Var.collection.name`
- Entity references: `Ent.collection.name`
- List value references: `Ls.collection.list.key`
- Card references: `Card.CurrentContextCard` *(see below)*
- Nested function calls: `Fn.collection.Func(...)` (if supported by the
  function declaration)

### `Card.CurrentContextCard`

A special argument token that resolves to the current card's full payload
dictionary at evaluation time. The Dispatcher maintains a "context card"
set by the runtime immediately before any `output_selector` or card function
call is dispatched.

Typical use — skill check:

```
output_selector: "Fn.global.CheckSkill(Card.CurrentContextCard)"
```

The function receives the card dict and can read `card.data.threshold`,
`card.data.skill`, etc. without needing to perform its own card lookup.

Parsed AST node: `{"type": "card_ref", "name": "CurrentContextCard"}`.
Evaluates by returning `Dispatcher._context_card` (set before dispatch;
defaults to `{}`).

---

## Parser

### `expression_parser.gd`

Implements a recursive descent parser. Input: expression string.
Output: an AST represented as nested Dictionaries (GDScript has no
algebraic types; Dictionary is idiomatic).

### AST Node Types

```gdscript
# Condition node types
{ "type": "and", "left": <node>, "right": <node> }
{ "type": "or",  "left": <node>, "right": <node> }
{ "type": "not", "operand": <node> }
{ "type": "bool_literal", "value": true/false }
{ "type": "call", "prefix": "Fn", "collection": String,
                  "name": String, "args": Array }

# Argument node types
{ "type": "bool_literal",  "value": bool }
{ "type": "int_literal",   "value": int }
{ "type": "float_literal", "value": float }
{ "type": "string_literal","value": String }
{ "type": "ref", "prefix": "Var"/"Ent"/"Ls",
                 "collection": String, "name": String,
                 "key": String }   # key only for Ls
```

### Parser API

```gdscript
class ExpressionParser:
    # Returns AST root node, or null on empty string (always-true).
    # Raises a descriptive error string on parse failure.
    static func parse_condition(expr: String) -> Variant

    # Returns a single call AST node.
    # Used for switch expressions (must resolve to a String).
    static func parse_call(expr: String) -> Dictionary
```

Parsing happens on first access, not at every evaluation.
Parsed ASTs are cached in memory keyed by the expression string.

---

## Binding Registry

### `binding_registry.gd`

A Dictionary mapping `collection_name` to an implementation Object, separated
by prefix type.

```gdscript
class BindingRegistry:
    var _fn_bindings: Dictionary  = {}  # collection_name → Object
    var _var_bindings: Dictionary = {}  # collection_name → Object
    var _ent_bindings: Dictionary = {}  # collection_name → Object

    func bind_function_collection(collection_name: String, impl: Object) -> void
    func bind_variable_collection(collection_name: String, impl: Object) -> void
    func bind_entity_collection(collection_name: String, impl: Object) -> void

    func get_fn_impl(collection_name: String) -> Object   # null if not bound
    func get_var_impl(collection_name: String) -> Object
    func get_ent_impl(collection_name: String) -> Object
```

The registry is owned by `TarinoiRuntime` and populated by game code during
`_ready()` before any dialogue starts.

**Note on lists.** `Ls` references resolve to a concrete value (the
`option_value` of the matching `TListOptionSpec`) by looking up the list in
SQLite. They do not require game-side binding. The Dispatcher resolves them
directly from the DB.

**Note on variables.** `Var` references are passed to function implementations
as `VarRef` proxy objects — see `VarRef` section below. They are *not*
evaluated to their current value before the call.

---

## Dispatcher

### `dispatcher.gd`

Takes a parsed AST node, resolves references, and returns a value.

```gdscript
class Dispatcher:
    var _registry: BindingRegistry
    var _lists: Dictionary       # populated by set_lists() from TarinoiRuntime

    # Evaluates a condition expression string. Returns bool.
    # Logs error on unbound collection; returns false as safe default.
    func eval_condition(expr: String) -> bool

    # Evaluates a function-call expression string. Returns Variant.
    # Logs error if function not found; returns "" as safe default.
    func eval_call(expr: String) -> Variant

    # Evaluates any expression string. Returns Variant (not coerced to bool).
    func eval_value(expr: String) -> Variant

    # Returns true if the function named in a call expression is bound and callable.
    func has_call(expr: String) -> bool
```

### `eval_condition` Logic

The Dispatcher parses the expression string on first call and caches the AST.
Evaluation walks the AST:

```
null (empty condition) → return true
bool_literal           → return value
not                    → return !eval(operand)
and                    → return eval(left) && eval(right)  (short-circuits)
or                     → return eval(left) || eval(right)  (short-circuits)
call                   → return _dispatch_fn(node) cast to bool
```

### `eval_call` Logic

```
1. Parse expression string → call AST node (cached)
2. Look up collection impl: _registry.get_fn_impl(node.collection)
   → logs error and returns false if null
3. Resolve each arg recursively
4. Call impl.<node.name>(resolved_args...) via callv()
   → logs error and returns false if method not found
5. Return result
```

### Argument resolution

```
bool/int/float/string literal → return value directly
Var ref  → VarRef.new(get_var_impl(collection), collection, name)
           (NOT evaluated — the function receives a proxy, not a value)
Ent ref  → get_ent_impl(collection).get_entity(name) → Variant
Ls ref   → look up key in _lists["collection/list_id"] → return option_value
card_ref → return _context_card (the current card's full payload dict)
```

### Error Handling

All dispatch errors are non-fatal. The Dispatcher logs via `TarinoiLogger.error()`
and returns a safe default (`false` for conditions, `""` for call expressions).
The runtime continues after a dispatch error — the dialogue may be incorrect
but will not crash.

---

## VarRef

### `var_ref.gd`

A proxy object passed to function implementations when a `Var.collection.name`
expression appears as an argument. Lets the implementation read, write, or
both without needing to know about the registry.

```gdscript
class VarRef:
    var name: String        # variable name within the collection
    var collection: String  # collection_name the variable belongs to

    func get_value() -> Variant          # reads current value
    func set_value(v: Variant) -> void   # writes value back

    # Convenience: unwraps a VarRef to its value.
    # Passes non-VarRef values through unchanged.
    # Use in function implementations that only need to read.
    static func resolve(v: Variant) -> Variant
```

### Usage patterns

```gdscript
# Read-only argument — use VarRef.resolve() for transparent handling:
func PersuasionCheck(threshold: Variant) -> bool:
    return _vars.get_variable("persuasion_score") >= int(VarRef.resolve(threshold))

# Write argument — use set_value() directly:
func SetFlag(flag_ref: Variant) -> void:
    flag_ref.set_value(true)

# Read-then-write:
func ConsumeKeycard(card_ref: Variant) -> bool:
    if not card_ref.get_value():
        return false
    card_ref.set_value(false)
    return true
```

`Ls` references always resolve to their concrete `option_value` (read-only
constants). `Ent` references call `get_entity(name)` on the bound entity
collection and return whatever the game provides.

---

## Binding Protocol: What Game Code Must Implement

### Function Collection

```gdscript
# One class per function collection. Class name is conventional, not enforced.
class GameFunctions:
    # Each bound function is a method with the exact name matching
    # the Tarinoi function_name. Arguments match function_args in declaration.
    func SkillCheck(skill: Variant, threshold: Variant) -> bool:
        ...
    func MyFunnyGate(flag: Variant) -> bool:
        ...
```

### Variable Collection

```gdscript
class GameVariables:
    func get_variable(variable_name: String) -> Variant:
        ...
    func set_variable(variable_name: String, value: Variant) -> void:
        ...
```

Variable collections do not have per-variable methods. All reads and writes
go through `get_variable` / `set_variable` with the variable name as a string
argument. The game's variable store (savegame system, blackboard, etc.)
handles the actual storage.

### Entity Collection

```gdscript
class GameEntities:
    # Returns whatever the game considers an entity reference —
    # could be a Dictionary, a Node path, an ID string, etc.
    func get_entity(entity_name: String) -> Variant:
        ...
```

---

## Registration Example (game code)

```gdscript
# In demo.gd or game's main scene _ready():
func _ready():
    var runtime = TarinoiRuntime

    runtime.registry.bind_function_collection("global", GameFunctions.new())
    runtime.registry.bind_function_collection("checks", CheckFunctions.new())
    runtime.registry.bind_variable_collection("player", PlayerVariables.new())
    runtime.registry.bind_entity_collection("major", MajorEntities.new())
```

---

## AST Caching

The expression parser is called once per unique expression string, at first
evaluation. Results are cached in a Dictionary on the Dispatcher:

```gdscript
var _ast_cache: Dictionary = {}   # expr_string → AST node
```

Cache is per-session (not persisted). Since expression strings come from
the SQLite DB and don't change without a sync, the cache is valid for the
entire game session after a sync.
