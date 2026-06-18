# Tarinoi Plugin Developer Guide

*(Game Engine Integration — April 2026)*

---

## 1. Purpose and scope

This guide is for game programmers building a Tarinoi plugin for Godot, Unity, Unreal, or any other engine. It describes the data model as it appears in a Clio-managed Git repository, explains the conventions a plugin needs to understand, and defines the boundary between what Tarinoi owns and what the game engine owns.

The reference implementation is the Godot plugin. Code examples in this guide use a pseudocode notation that maps straightforwardly to GDScript, C#, or Python.

---

## 2. Design philosophy

Tarinoi is **unopinionated**. It does not provide a function library, it does not know which dialogue fires when the player walks into a room, and it does not care whether your game is a tech-tree strategy, a rhizomatic RPG, or a point-and-click adventure.

The division of responsibility is clean:

| Tarinoi | The plugin | The game engine |
|---------|-----------|-----------------|
| Authoring tool and data contract | Graph traversal and expression dispatch | Function implementations, variable scope, persistence, triggers, presentation |

The plugin is nearly stateless. It receives a pointer to a start card and walks the graph, dispatching expression calls to game-provided implementations and returning the next card to present. All decisions about what to do with that information — what to show on screen, whether to save state, how to trigger the dialogue in the first place — belong to the game.

---

## 3. The repository layout

When Clio commits a project, the Git repository has this layout:

```
{projectId}/
  {branch}/                     ← Git repo root
    .tarinoi/
      state.json                ← flush cursor (internal; ignore)
    boards/
      {collectionId}/
        collection.json         ← collection manifest
        manifest.json           ← bucket index
        b-000.json … b-{N}.json ← card documents (hash-bucketed)
    entities/
      {collectionId}/
        collection.json
        b-000.json … b-{N}.json ← entity documents
    variables/
      {collectionId}/
        collection.json
        b-000.json … b-{N}.json ← variable declarations
    functions/
      {collectionId}/
        collection.json
        b-000.json … b-{N}.json ← function declarations
    lists/
      {collectionId}/
        collection.json
        b-000.json … b-{N}.json ← list specifications
    templates/
      {collectionId}/
        collection.json
        b-000.json … b-{N}.json ← card and entity templates
    folders/
      …
```

### Reading documents

All documents share a common envelope:

```json
{
  "document_id": "…",
  "collection_id": "…",
  "document_type": "card",
  "payload": { … }
}
```

The `payload` field contains the document-type-specific data. Everything the plugin needs is in `payload`.

Documents are distributed across `b-000.json … b-{N}.json` bucket files. Each bucket file is a JSON **object keyed by `document_id`**, not an array. To load all documents from a collection, read every bucket file and iterate over the object's values. The `manifest.json` lists the bucket files in order.

`collection.json` is a document envelope whose **`document_id`** is the collection's own ID. (`collection_id` on that same file refers to the parent collection and should be ignored when populating the collections table.)

---

## 4. Relevant document types

### 4.1 Cards (`document_type: "card"`)

Found in `boards/`. Cards are the nodes of a dialogue graph.

Key payload fields:

| Field | Type | Meaning |
|-------|------|---------|
| `base_ref` | string | The built-in card type. See §5. |
| `structural` | boolean? | If true, the card controls flow (start, jump) rather than presenting content. |
| `entity_ref` | string? | The `entity_name` of the speaking entity. |
| `input_pin` | TCardPin? | The condition required to enter this card. |
| `output_pins` | TCardPin[]? | Outgoing wires, each with an optional condition. |
| `output_selector` | string? | Expression that selects an output pin by name. See §7.2. |
| `connections` | string[]? | Wires to other cards. See §6. |
| `geo` | TCardGeometry | Visual position in the authoring tool. See §8. |
| `data` | object | Template-defined property values, keyed by property name. May contain `Fn.*` call expressions that the runtime evaluates as side effects. See §7.4. |
| `props` | `{ name: string, data_type: string }[]`? | Ordered declaration of the properties present in `data`. Used by the runtime to determine evaluation order when multiple function expressions exist. **Note:** `props` may not always declare every key present in `data` (e.g. when a card template is updated after the card was authored). Never treat `props` as an exhaustive list of what `data` contains — treat it as an ordering hint only. |

### 4.2 Entities (`document_type: "entity"`)

Found in `entities/`. Entities are characters, objects, or anything that can participate in dialogue.

Key payload fields:

| Field | Type | Meaning |
|-------|------|---------|
| `entity_name` | string | Unique identifier; used as `entity_ref` on cards. |
| `dialog_capable` | boolean | If false, the entity does not speak. |
| `is_player_character` | boolean? | Marks the player character. |
| `has_avatar` | boolean | Whether the entity has avatar images. |
| `avatar_refs` | TAvatarRef[] | Avatar variants. See §9. |
| `data` | object | Template-defined property values. |

### 4.3 Function declarations (`document_type: "function-declaration"`)

Found in `functions/`. A function declaration is a named call that the plugin will dispatch to a game-provided implementation at runtime.

Key payload fields:

| Field | Type | Meaning |
|-------|------|---------|
| `function_name` | string | Identifier used in expressions. |
| `function_args` | TArgDeclaration[] | Argument types and reference sub-types. |
| `function_returns` | string | Return type (`"string"`, `"number"`, `"boolean"`, `"void"`, `"any"`). |
| `function_effect` | string | `"pure"`, `"side-effect"`, or `"mutation"`. |

### 4.4 Variable declarations (`document_type: "variable-declaration"`)

Found in `variables/`. Variables appear as arguments in expressions, addressed via member syntax (`Var.group.name`). Their scope, persistence, and storage are owned entirely by the game.

| Field | Type | Meaning |
|-------|------|---------|
| `variable_name` | string | Leaf name in `Var.group.variable_name`. |
| `data_type` | string | `"string"`, `"number"`, `"boolean"`, or `"list-reference"`. |
| `default_value` | any? | Suggested initial value; game engine owns lifecycle. |

### 4.5 List specifications (`document_type: "list-spec"`)

Found in `lists/`. Lists are named enumerations. They appear as argument types in function declarations and as data property values on cards.

| Field | Type | Meaning |
|-------|------|---------|
| `list_name` | string | Identifier. |
| `data_type` | string | The type of `value` in each option. |
| `list_options` | `{ key: string, value: string|number }[]` | The enumeration. |

---

## 5. Card base types

Every card has a `base_ref` that identifies its built-in role:

| `base_ref` | `structural` | Meaning |
|------------|-------------|---------|
| `start` | true | Entry point to the graph. Find by filtering `base_ref === "start"`. Multiple start cards may exist in one board; authors use them to provide different entry points. |
| `line` | — | A line of dialogue. The speaking entity is in `entity_ref`; the line text is in `data.line`. |
| `blank` | — | A generic content card with no built-in fields. Template-defined `data` only. |
| `media` | — | References an authoring-support asset. See §10. |
| `jump` | true | Unconditionally transfers flow to another card. Target is in `data.target` (a card ID). |
| `annotation` | — | An author note. Has no output pins; never presented to the player. |
| `backdrop` | true | A background grouping device in the authoring tool. Has no output pins. |

Cards with no `input_pin` and no `output_pins` (`annotation`, `backdrop`) are authoring artefacts. Skip them during traversal.

---

## 6. Connections and end-of-flow

`connections` is an array of wire strings. Each entry has the form:

```
"{sourcePinName}>>{targetCardId}"
```

The special target value `"flow:end"` (exported as `MBuiltinConnection.END_FLOW`) signals that flow terminates rather than advancing to another card:

```
"default>>flow:end"
```

**Parsing a connection:**

```
parts = connection.split(">>")
from_pin = parts[0]       # e.g. "default", "yes", "no"
to_card  = parts[1]       # a document_id, or "flow:end"
```

To find where a given output pin leads, find the connection whose `from_pin` matches the pin name.

---

## 7. Expressions

### 7.1 Grammar

Conditions (`TCardPin.condition`) and output selectors (`TCard.output_selector`) are serialised expression strings. The grammar is intentionally restricted:

- **Call expressions**: `functionName(arg1, arg2, …)`
- **Member expressions**: `Namespace.group.name`
- **Boolean combinators**: `&&`, `||`, `!`, and parenthesised groupings

There are no arithmetic operators, comparison operators, or string literals. All values enter through function calls and member lookups.

An empty condition string means the pin is unconditional — it is always active.

### 7.2 Variable references

Variables are referenced in function arguments using the member expression syntax:

```
Var.ferryman.met_the_ferryman
```

`Var` is the root namespace. The next segment is the variable collection name; the leaf is `variable_name`. The plugin resolves this token by looking up the variable declaration and asking the game engine for the current value.

### 7.3 Binding pattern

The plugin does not implement functions — it dispatches to implementations registered by the game. The recommended pattern mirrors Tarinoi's own RPC interface binding:

```
# Registration (game side)
plugin.bind("flags.CheckFlag",  my_check_flag_impl)
plugin.bind("flags.SetFlag",    my_set_flag_impl)
plugin.bind("stats.GetHealth",  my_get_health_impl)

# Evaluation (plugin side)
fn evaluate_call(name, args):
    impl = bindings[name]
    if impl == null:
        push_error("Unbound function: " + name)
        return null
    return impl.call(args)
```

Functions declared with `function_effect: "mutation"` or `"side-effect"` may alter game state. The plugin must call them in declaration order, not speculatively.

### 7.4 Evaluating a condition

Walk the parsed expression tree:

- **Call node**: resolve arguments (recursively evaluating member expressions), dispatch to bound implementation.
- **Member node** rooted at `Var`: look up the variable value from the game.
- **Logical node** (`&&`, `||`, `!`): evaluate operands and combine.
- **Empty string**: return `true`.

### 7.4 Function expressions in `card.data`

Any string value in `card.data` that matches the `Fn.*` call pattern is a **side-effect expression** — a function the runtime must call when the card is "committed to":

- **NPC line card**: when the line is shown to the player (before `line_ready`).
- **PC choice card**: when the player selects that choice (not when choices are presented — unchosen candidates must not have their functions evaluated).
- **Blank / start / jump / structural**: immediately on traversal, before following connections.

Evaluation order is determined by the position of each property name in `card.props`. Function expressions not listed in `props` are evaluated last (preserve any stable iteration order the runtime uses for dictionary keys).

The `Card.CurrentContextCard` token may be passed as an argument to receive the current card's full payload dictionary at evaluation time:

```
Fn.global.CheckSkill(Card.CurrentContextCard)
```

This is the standard pattern for skill-check cards that need to read their own `data.threshold` or `data.skill` fields at call time.

Return values from data function expressions are discarded. These functions are always `void` or `side-effect` from the runtime's perspective. Functions that need to influence routing should be placed in `output_selector`, not in `data`.

### 7.5 Output selector

When a card has an `output_selector`, evaluate it as a call expression. The return value must be a string matching one of the card's `output_pins[].name` values. Use that pin name to look up the corresponding connection and advance to the target card. If no pin name matches, treat it as an error.

---

## 8. Choice display order

When a card has multiple output pins, the target cards should be presented to the player in **ascending `geo.y` order**. Authors use the vertical position of cards in the graph editor to express the intended display order of choices.

```
choices = output_pins
    .map(pin -> resolve_connection_target(pin.name))
    .filter(card -> card != null && card != END_FLOW)
    .sort_by(card -> card.payload.geo.y)
```

---

## 9. Entities and avatars

### Filtering entities

Only entities with `dialog_capable: true` speak in dialogue. The entity referenced by `entity_ref` on a `line` card is guaranteed to be dialog-capable.

`is_player_character: true` marks the player. Entities without this flag are NPCs. There is at most one player character per project.

### Avatars

`avatar_refs` lists the available avatar variants for an entity:

```json
{
  "variant": "default",
  "link": "ferryman--default",
  "version": 3
}
```

`link` has the form `{entity_name}--{avatar_name}` and is the stable, unique identifier for that image.

**Avatars stored in Tarinoi are low-resolution authoring aids (320×320 webp). They are not game-ready assets.** The plugin's codegen phase should write placeholder files at `avatars/{link}.webp` so that artists can see what goes where, but it must not overwrite a file that already exists — the game's production assets take precedence.

The choice of *which* variant to display in a given scene, and how to present it, belongs to the game engine. Tarinoi does not express display intent for avatars.

---

## 10. Media assets

Cards with `base_ref: "media"` reference images stored in Tarinoi via a `clio://` URL in `data.media_link`. These are **authoring-support assets** — illustrations, moodboards, and reference images used during writing. They are not designed for in-game use.

The game engine is expected to supply its own media assets through its own pipeline. A plugin may read `clio://` URLs for authoring context (e.g. to display reference art in an editor window), but should not serve them to players.

---

## 11. Codegen

The plugin's codegen phase runs at project import time and produces engine-native types from Tarinoi templates. This gives game code type-safe access to `data` fields without string key lookups at runtime.

### Typed data wrappers

For each card template and entity template in `templates/`, generate a class or struct whose fields correspond to the template's `props` array. Example from a `line` template in C#:

```csharp
// Generated from template "line_with_tags"
public class LineWithTagsData {
    public string Line { get; set; }
    public string[] Tags { get; set; }
}
```

Access in game code:

```csharp
var d = card.Data<LineWithTagsData>();
string text = d.Line;
```

### Avatar placeholders

For each `TAvatarRef` across all entities, write `avatars/{link}.webp` if the file does not already exist. Copy the low-res Tarinoi webp as a placeholder; artists replace it with production art.

### Start card index

Generate a lookup table mapping a human-readable name to a `document_id`, populated from whatever naming convention the project uses (e.g. `label`, or a naming annotation if one is added in a future release). This lets game code trigger a specific dialogue without hard-coding document IDs.

---

## 12. Graph traversal walkthrough

```
fn run_dialogue(start_card_id):
    card = load_card(start_card_id)
    assert card.payload.base_ref == "start"

    while true:
        card = advance(card)
        if card == null:
            break           # end of flow
        present(card)       # game engine renders the card

fn advance(card):
    pins = card.payload.output_pins ?? []

    if len(pins) == 0:
        return null         # no exits — end of flow

    if card.payload.output_selector:
        # function call selects which pin to follow
        pin_name = evaluate_expression(card.payload.output_selector)
        return follow_pin(card, pin_name)

    # evaluate pin conditions; collect active pins
    active = pins.filter(pin -> evaluate_condition(pin.condition))

    if len(active) == 0:
        return null         # no active pin — end of flow

    if len(active) == 1:
        return follow_pin(card, active[0].name)

    # multiple active pins: present choices to player, sorted by geo.y
    choices = active
        .map(pin -> { pin: pin, target: peek_target(card, pin.name) })
        .filter(c -> c.target != null)
        .sort_by(c -> c.target.payload.geo.y)
    chosen_pin = await player_chooses(choices)
    return follow_pin(card, chosen_pin.name)

fn follow_pin(card, pin_name):
    conn = card.payload.connections
        .find(c -> c.split(">>")[0] == pin_name)
    if conn == null:
        return null
    target_id = conn.split(">>")[1]
    if target_id == "flow:end":
        return null
    return load_card(target_id)
```

Jump cards (`base_ref: "jump"`) require special handling — follow `data.target` instead of an output pin:

```
if card.payload.base_ref == "jump":
    return load_card(card.payload.data["target"])
```

---

## 13. Godot plugin — provided scenes and nodes

The Godot reference implementation ships ready-to-use scenes and trigger nodes in `addons/tarinoi/`. Developers can use them out of the box or replace them with game-specific equivalents.

### TarinoiChooseStart (`addons/tarinoi/scenes/choose_start.tscn`)

A generic start-card picker. Drop into any `Control` hierarchy.

- Auto-populates on `TarinoiRuntime.sync_completed`. Also populates immediately if content is already loaded.
- Buttons call `TarinoiRuntime.start_dialogue()` and emit `start_selected(collection_id, card_id)`.
- Shows a status label while syncing or if no cards are found.

```gdscript
var picker := preload("res://addons/tarinoi/scenes/choose_start.tscn").instantiate()
picker.start_selected.connect(func(col, card): print("selected ", col, card))
add_child(picker)
```

### TarinoiDialogueStrip (`addons/tarinoi/scenes/dialogue_strip.tscn`)

A scrolling dialogue feed. Drop into any `Control` hierarchy.

**Auto-connects on `_ready()`:** `line_ready → show_line`, `choices_ready → show_choices`, `pin_choice_needed → show_pins`.

**The parent scene must handle `dialogue_ended`** and call `hide_strip()` when it fires.

Public API:

| Method | Behaviour |
|--------|-----------|
| `show_line(line_data)` | Displays an NPC line or system message and shows the strip. |
| `show_choices(choices)` | Displays numbered choice buttons and shows the strip. |
| `show_pins(pin_names)` | Dev mode: displays named output pins for manual selection. |
| `hide_strip()` | Clears the feed and hides the strip. |

Input handling is built in: `Space` / `ui_accept` advances NPC lines; `1`–`9` keys and mouse clicks select choices.

To use your own dialogue UI instead, simply don't add `DialogueStrip` — connect `TarinoiRuntime.line_ready`, `choices_ready`, `dialogue_ended`, and `pin_choice_needed` to your own implementation.

### TarinoiQuickStart (`addons/tarinoi/scenes/tarinoi_quickstart.tscn`)

Combines `TarinoiChooseStart` and `TarinoiDialogueStrip` into a self-contained scene. Calls `TarinoiRuntime.configure()` and `sync()` automatically.

Override `_setup_bindings()` in a subclass to wire game logic:

```gdscript
# res://my_quickstart.gd
extends "res://addons/tarinoi/scenes/tarinoi_quickstart.gd"

func _setup_bindings() -> void:
    var vars := MyVariables.new()
    TarinoiRuntime.registry.bind_variable_collection("global", vars)
    TarinoiRuntime.registry.bind_function_collection("global", MyFunctions.new(vars))
```

**Tools > Tarinoi: Initialize project** scaffolds this subclass and a companion `.tscn` at `res://` automatically.

### DialogueTrigger / DialogueTrigger2D (`addons/tarinoi/nodes/`)

Trigger nodes for 3D and 2D scenes respectively. Set `collection_id` and `card_id` in the Inspector, then call `activate()` from player code.

```gdscript
# In your player controller, when interact key is pressed near the trigger:
trigger.activate()

# Wire up:
trigger.interaction_triggered.connect(func(col_id, card_id):
    TarinoiRuntime.start_dialogue(col_id, card_id)
)
```

**Editor helper:** leave both IDs empty — the Output panel prints all available start cards on scene open so you can copy the correct UUIDs into the Inspector.

---

## 14. Data access

`TarinoiRuntime.data` is a `TarinoiDataAccess` instance (see `addons/tarinoi/core/data_access.gd`) that exposes document lookups outside the dialogue flow. It is populated after `configure()` and is `null` before that.

### `get_document(document_id, collection_id = "")`

Returns the active payload dict for any document, or `{}` if not found. This method is a coroutine in the default SQLite implementation — use `await`:

```gdscript
var card_payload: Dictionary = await TarinoiRuntime.data.get_document("abc123xyz")
var entity_payload: Dictionary = await TarinoiRuntime.data.get_document("abc123xyz", "col456")
```

Two-layer merge is applied at the SQL level via the same `active_filter()` used by the dialogue engine:
- A buffer-layer document beats the main-layer document.
- An **inactive** buffer (archived/moved/tombstoned) **suppresses** the main-layer document — neither is returned.

`collection_id` is optional. Because document IDs are 21-character nanoids, the same ID appearing in two collections is not a realistic concern; the parameter exists for disambiguation if needed.

### `get_entity(identifier)`

Returns the entity payload for the entity with the given `identifier`, or `{}` if not found.

```gdscript
var ferryman := TarinoiRuntime.data.get_entity("ferryman")
var label: String = ferryman.get("label", "")
```

Reads from the in-memory entity cache (`_entities`) that the runtime populates on `configure()` and refreshes after every sync. The cache covers all entities, not just `dialog_capable` ones.

---

## 15. Visited-choice history

The plugin can dim choices the player has already traversed. Because the plugin does not own persistence, this is opt-in: you supply an implementation that stores and retrieves visited card IDs keyed by the start card of the dialogue.

### Interface

`TarinoiHistoryStore` (in `addons/tarinoi/core/history_store.gd`) defines two methods:

| Method | Signature | Meaning |
|--------|-----------|---------|
| `get_visited` | `(start_card_id: String) -> Array` | Return the list of visited choice card IDs for this entry point. Return `[]` if nothing recorded. |
| `save_visited` | `(start_card_id: String, visited_ids: Array) -> void` | Persist the complete visited set for this entry point. |

The base class implementations are no-ops. Subclass it to persist to a save file.

### Lifecycle

- **On `start_dialogue(collection_id, card_id)`:** the runtime calls `get_visited(card_id)` and seeds the session set from the result. The key is `card_id` (the start card of the dialogue).
- **During the dialogue:** each `select_choice()` call adds the chosen card's ID to the session set.
- **On `dialogue_ended` or `abort_dialogue()`:** the runtime calls `save_visited(start_card_id, visited_ids)` with the full accumulated set, merging current and prior visits.

### The `visited` flag on choices

Every dict in the array emitted by `choices_ready` includes:

```
"visited": bool   # true if this card's ID is in the current session set
```

This flag is false when `history_store` is null. Use it in your choice UI to dim previously-taken branches.

### Default in-memory implementation

`TarinoiHistoryStore.InMemory` is a ready-to-use subclass that stores the visited sets in a `Dictionary`. It resets when the object is freed (e.g. on scene restart), which gives within-session tracking without any save-file plumbing.

```gdscript
# In your scene's _ready():
TarinoiRuntime.history_store = TarinoiHistoryStore.InMemory.new()
```

### Custom save-file implementation

```gdscript
class MySaveHistory extends TarinoiHistoryStore:
    func get_visited(start_card_id: String) -> Array:
        return MySaveFile.load_visited(start_card_id)

    func save_visited(start_card_id: String, visited_ids: Array) -> void:
        MySaveFile.store_visited(start_card_id, visited_ids)
```

Assign before the first `start_dialogue()` call. The plugin makes no assumptions about when or how you persist the data.

---

## 16. Data providers

`TarinoiDataAccess` is now an abstract base class (see `addons/tarinoi/core/data_access.gd`). The default implementation (`TarinoiDataAccess.Sync`) runs all queries synchronously on the main thread via the bundled SQLite extension. You can replace it with your own implementation to put queries on a worker thread, use a different storage backend, or intercept calls for testing.

### How to swap the provider

**Option A — assign before `configure()`:**

```gdscript
# In your quickstart/scene _ready(), before calling TarinoiRuntime.configure():
TarinoiRuntime.data = MyFastDataAccess.new()
TarinoiRuntime.configure()
```

**Option B — ProjectSetting:**

Set `tarinoi/data_provider` to the resource path of your provider script. TarinoiRuntime instantiates it with `new()` during `configure()`. Leave the setting empty to use the default SQLite implementation.

This lets you set different providers per export preset or build configuration without touching game code.

### Implementing a provider

For most cases — including putting queries on a worker thread — subclass `TarinoiDataAccess.Sync` and override `_query()`:

```gdscript
class_name FastDataAccess
extends TarinoiDataAccess.Sync

signal _query_done(result: Array)

func _query(sql: String, params: Array = []) -> Array:
    WorkerThreadPool.add_task(func():
        var rows := _db.query_rows(sql, params)
        call_deferred("emit_signal", "_query_done", rows)
    )
    return await _query_done
```

All accessor methods (`load_card`, `get_document`, `query_start_cards`) automatically route through `_query()`, so overriding it is the only change needed. Callers `await` the result; for the default sync implementation, the `await` resolves in the same frame with zero latency.

For a fully custom backend (not SQLite at all), extend `TarinoiDataAccess` directly and override `get_document`, `get_entity`, `load_card`, and `query_start_cards` individually.

### configure() and _setup()

When `configure()` creates or discovers a provider, it calls `data._setup(db, runtime)`. The SQLite inner class uses this to capture the `TarinoiDB` instance and the runtime node. Custom providers that extend `TarinoiDataAccess` directly and manage their own storage can ignore it (the base class no-op is fine).

### What is NOT routed through the provider

`_load_global_cache()` (collections, entities, lists) runs at `configure()` time via direct SQLite access. It is a startup-only operation and intentionally excluded from the async path. The in-memory cache it populates is still accessible via `data.get_entity()`.

### Breaking change: `data.get_document()` is now async

Because `get_document()` routes through `_query()`, it is now a coroutine in the SQLite implementation. Call sites must use `await`:

```gdscript
# Before:
var payload := TarinoiRuntime.data.get_document("abc123xyz")

# After:
var payload: Dictionary = await TarinoiRuntime.data.get_document("abc123xyz")
```

`get_entity()` is not affected — it reads from the in-memory cache and remains synchronous.

`get_start_cards()` on TarinoiRuntime is also now a coroutine; use `await TarinoiRuntime.get_start_cards()`.

---

## 17. What the plugin does NOT own

| Concern | Owner |
|---------|-------|
| Which dialogue fires when | Game engine |
| Variable scope (global, scene, local) | Game engine |
| Variable persistence (save file) | Game engine |
| VO audio playback | Game engine |
| Avatar selection and animation | Game engine |
| Function implementations | Game engine |
| Player input / choice UI | Game engine |
| Visited-node history (long-term) | Game engine (plugin provides the interface and a short-term default) |
| In-game media assets | Game engine |

The plugin's job is: **walk the graph, dispatch expressions, return cards**. Everything else is the game's.
