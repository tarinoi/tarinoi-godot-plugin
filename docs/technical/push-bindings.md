# SPEC: Push Bindings to Tarinoi

## Purpose

Allow developers to push variable and function declarations from GDScript back
into Tarinoi via the write REST API. This closes the authoring loop: new
variables or functions added on the game side appear in Tarinoi without
requiring the author to re-declare them manually.

Cards and entities are explicitly out of scope — they are schema-dependent,
collision-prone, and owned by Tarinoi authors.

Requires the write API to be configured (see SPEC-API-SYNC.md).

---

## Scope

| Document type | Supported | Notes |
|---|---|---|
| Variable declarations | Yes | Full push: name, type, default value |
| Function declarations | Yes | Structural push; semantic fields default and may need enrichment in Tarinoi |
| Entity declarations | No | — |
| Cards | No | — |

---

## Safety model

The write API always targets the **buffer layer**
(`tarinoi:main-project-layer.buffer`). Pushed declarations are visible in
Tarinoi as uncommitted changes. Authors review and commit from within Tarinoi.
The committed main layer is never touched by a push. A push can always be
reverted in Tarinoi independently of any other changes.

---

## GDScript Conventions

### Variable binding implementation

The implementation class must contain:

1. A `var _store: Dictionary` initialised with all variables, their names as
   keys and their default values as values. Default values must not be `null`
   — the type is inferred from the value (`bool` → `boolean`,
   `int`/`float` → `number`, `String` → `string`).

2. A constant declaring the Tarinoi collection identifier:

```gdscript
class_name GlobalVariables

const TARINOI_COLLECTION := "global"

var _store: Dictionary = {
    "is_earthling":  false,
    "pc_health":     0,
    "player_name":   "",
}

func get_variable(name: String) -> Variant:
    return _store.get(name, null)

func set_variable(name: String, value: Variant) -> void:
    _store[name] = value
```

`TARINOI_COLLECTION` is the programmatic identifier of the variable collection
in Tarinoi (the `identifier` field on the collection manifest), not its display
label.

### Function binding implementation

The implementation class must `extends` the generated base class for its
collection. The generated base class is the inner class inside
`TarinoiFunctions` corresponding to the collection:

```gdscript
class_name GlobalFunctions
extends TarinoiFunctions.Global

func CheckFlag(flag_ref: Variant) -> bool:
    return bool(VarRef.resolve(flag_ref))
```

The `extends` relationship encodes collection identity (the plugin knows this
class belongs to the `global` collection because it extends `TarinoiFunctions.Global`)
and provides the diff target (methods in the implementation but absent from the
generated base = new functions to push).

---

## Comment Annotation Convention

The push mechanism reads `##` doc comments immediately preceding each `func`
declaration to extract `function_effect` and per-argument `sub_type`.

**Defaults (applied when no comment is present):**
- `function_effect`: `pure`
- arg `sub_type`: `literal`

**Override syntax:**

```gdscript
## effect: <pure|side-effect|mutation>
## arg <name>: <sub_type>
func FunctionName(...) -> ...:
```

`sub_type` values match Tarinoi's arg declaration: `literal`,
`variable-reference`, `entity-reference`, `list-reference`,
`deep-entity-reference`, `context-card`.

**Codegen generates these comments** in every function stub so that developers
immediately see the current Tarinoi values and the expected format:

```gdscript
## CheckFlag(flag_ref) -> boolean
## effect: pure
## arg flag_ref: variable-reference
func CheckFlag(flag_ref: Variant) -> Variant:
    push_error("TarinoiFunctions.Global.CheckFlag is not implemented")
    return false

## AdjustCounter(counter_ref, delta) -> void
## effect: side-effect
## arg counter_ref: variable-reference
## arg delta: literal
func AdjustCounter(counter_ref: Variant, delta: Variant) -> Variant:
    push_error("TarinoiFunctions.Global.AdjustCounter is not implemented")
    return null
```

When the developer adds a new function and wants to specify non-default
semantics, they write the comments above their implementation. If the comments
are absent or wrong, they can correct the values in Tarinoi after the push.

---

## New Project Setting

| Setting | Type | Default | Notes |
|---|---|---|---|
| `tarinoi/bindings_impl_path` | `STRING` | `"res://demo/bindings/impl/"` | Directory scanned for binding implementation scripts. |

The plugin scans only this directory (non-recursively) for `.gd` files. It
does not scan the entire project tree.

---

## Push Mechanism

Triggered by a new Tools menu item: **Tarinoi: Push bindings**.

The plugin:

1. Opens the local DB to resolve collection IDs and existing document IDs.
2. Scans `bindings_impl_path` for `.gd` files.
3. For each file, determines whether it is a variable or function implementation
   (see detection below) and runs the appropriate push.
4. POSTs the resulting document batch to `<api_path>/documents` as NDJSON.
5. Reports the result (count pushed, any errors) to the Godot Output panel.

### Variable push

Detection: the script defines `const TARINOI_COLLECTION`.

Steps:
1. Load the script resource; instantiate it to read `_store`.
2. Resolve the Tarinoi collection ID from the DB:
   `SELECT collection_id FROM collections WHERE collection_type = 'variable-collection' AND json_extract(payload, '$.identifier') = ?`
3. For each key/value pair in `_store`:
   a. Look up an existing `variable-declaration` document in the DB with
      `json_extract(payload, '$.identifier') = <key>` in that collection.
   b. Reuse its `document_id` if found; generate a new ID otherwise.
   c. Construct a `TVariableDeclaration` payload:
      - `identifier`: key
      - `data_type`: inferred from `typeof(value)` (`bool`→`boolean`,
        `int`/`float`→`number`, `String`→`string`)
      - `default_value`: value
4. Push all declarations as a single POST.

### Function push

Detection: the script's base class is `TarinoiFunctions.<Collection>`.

Steps:
1. Load both the implementation script and the generated base class script.
2. Derive the collection name from the base class inner class name (e.g.
   `TarinoiFunctions.Global` → collection identifier `"global"`, applying
   PascalCase→snake_case conversion).
3. Resolve the Tarinoi collection ID from the DB (same query as variables,
   using `function-collection`).
4. Diff method lists: methods present in the implementation but absent from
   the generated base class are candidates to push. Skip `_init` and any
   method whose name starts with `_`.
5. For each candidate method:
   a. Read arg names and types from `Script.get_script_method_list()`.
   b. Read the source file to extract `## effect:` and `## arg <name>:` doc
      comments immediately preceding the `func` line. Apply defaults where
      comments are absent.
   c. Look up an existing `function-declaration` document in the DB; reuse
      `document_id` if found, generate one otherwise.
   d. Construct a `TFunctionDeclaration` payload:
      - `identifier`: method name
      - `function_args`: from the script method list, with `sub_type` from
        comment or default `literal`
      - `function_returns`: from the script return type hint
      - `function_effect`: from comment or default `pure`
6. Push all declarations as a single POST.

---

## Codegen Changes

`_gen_functions` gains an `## effect:` and per-arg `## arg <name>: <sub_type>`
comment block above each function stub, populated from the existing `effect`
and `args` data already loaded from the DB. This requires no schema change —
the data is already available at codegen time.

The generated comments serve simultaneously as:
- Documentation for the developer reading the stub
- The canonical source for the push parser when the developer's annotation
  differs from the stub

---

## ID Generation

When a new variable or function has no existing DB record, the push needs a
fresh `document_id`. Use a random 21-character alphanumeric + `-_` string
(matching Tarinoi's NanoID format). A simple GDScript implementation suffices:

```gdscript
static func _new_id() -> String:
    const CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    var id := ""
    for i in 21:
        id += CHARS[randi() % CHARS.length()]
    return id
```

---

## Variable Removal

By default, the push only adds and updates — keys removed from `_store` are
not tombstoned in Tarinoi. This is safe because broken references are surfaced
automatically in Tarinoi on commit (pushed changes go to the buffer layer, so
authors see the impact before anything is committed).

A project setting enables deletion:

| Setting | Type | Default | Notes |
|---|---|---|---|
| `tarinoi/push_delete_removed` | `BOOL` | `false` | When true, variables and functions absent from the implementation but present in Tarinoi are tombstoned on push. |

When enabled, the push compares the full set of identifiers in the
implementation against all declarations in the DB for that collection and
tombstones any that are no longer present.

---

## Notes for Future Back-ports

`extends TarinoiFunctions.Global` (extending an inner class) is valid
GDScript 4 syntax and is the supported convention for this plugin. If a
back-port to an older Godot version is ever needed and inner class extends
proves problematic, the fallback is to drop the `extends` relationship and
instead use a `TARINOI_COLLECTION` constant plus a sibling
`const TARINOI_TYPE := "functions"` constant, mirroring the variable
collection convention.
