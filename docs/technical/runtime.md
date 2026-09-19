# Dialogue Runtime

## Responsibility

`TarinoiRuntime` is an Autoload singleton. It owns the dialogue state machine,
queries SQLite for card data, dispatches expressions via the Dispatcher, and
communicates with client UI nodes exclusively through signals.

It does not know about, reference, or depend on any UI node.

---

## State Machine

```
IDLE
  │  start_dialogue(collection_id, card_id)
  ▼
  (card loaded synchronously)
  │
  ▼
EVALUATING card type
  │
  ├─ base_ref = "start" / "blank" / "jump"  → transparent: follow connections immediately
  │
  ├─ base_ref = "line", entity is NPC  →  NPC_LINE  (emit line_ready, wait)
  │
  └─ base_ref = "line", entity is PC   →  PC_CHOICE  (emit choices_ready, wait)

NPC_LINE
  │  advance() called by client
  ▼
FOLLOW_CONNECTIONS  ← classify outgoing connections of the card just left
  │
  ├─ no connections              → IDLE (emit dialogue_ended)
  ├─ named pins (pass/fail/etc.) → output_selector evaluated if present
  │       ├─ output_selector bound  → follow matching pin
  │       └─ no selector / unbound  → AWAITING_PIN (emit pin_choice_needed, wait)
  ├─ single default connection   → load target card (loop back to EVALUATING)
  └─ multiple default connections → look-ahead: load all targets, keep "line"
                                    cards whose gates pass, sort by geo.y, then
                                    decide by the kind of set (below)

What kind of set a look-ahead produced decides how it is presented, matching
in-app playback (`usePlayback.getNextCards`):

- **Any PC line in the set** → it is a choice set. The PC lines are offered as
  `PC_CHOICE` in geo.y order; an NPC line mixed in is an authoring error and is
  dropped with a warning.
- **NPC lines only** → the author selects the line by its input condition, so
  only the **first** passing line (by geo.y) is shown, as `NPC_LINE`. Several
  passing lines are not a menu. Duplicate or empty conditions among them are
  warned about, since the later ones can never be reached.

A line is a PC line when its `line_mode` is `"pc"`; an NPC line when it is
`"npc"`; and when it is `"inherit"` or unset, the speaker decides — the
`entity_ref` entity's `is_player_character` flag (`_is_pc_card`).

PC_CHOICE
  │  select_choice(index) called by client
  ▼
  emit choice_made(card_data)
  FOLLOW_CONNECTIONS on the selected choice card  (same as above)

AWAITING_PIN
  │  select_pin(pin_name) called by client
  ▼
  load card at matching connection → EVALUATING (loop)
```

---

## Autoload: `TarinoiRuntime`

```gdscript
extends Node

# --- Dialogue API ---
func configure() -> void
func sync() -> void
func start_dialogue(collection_id: String, card_id: String) -> void
func advance() -> void                    # NPC lines only
func select_choice(index: int) -> void    # PC choices only
func select_pin(pin_name: String) -> void # AWAITING_PIN state only
func abort_dialogue() -> void             # resets to IDLE, emits dialogue_ended
func get_state() -> String                # "IDLE" | "NPC_LINE" | "PC_CHOICE" | "AWAITING_PIN"
func get_start_cards() -> Array           # [{card_id, collection_id, collection_label, label}]
func post_system_line(text: String) -> void  # queue interstitial from function impl
func eval_expression(expr: String) -> Variant

# --- Data access ---
var data: TarinoiDataAccess               # available after configure(); null before

# --- Visited-choice history ---
var history_store: TarinoiHistoryStore    # assign before start_dialogue(); null = no tracking

# --- Binding registration ---
var registry: BindingRegistry

# --- Signals ---
signal line_ready(line_data: Dictionary)
signal choices_ready(choices: Array)
signal dialogue_ended()
signal dialogue_error(message: String)
signal choice_made(card_data: Dictionary)
signal pin_choice_needed(pin_names: Array)
signal sync_started()
signal sync_completed(stats: Dictionary)
signal sync_failed(reason: String)
signal sync_progress(message: String, fraction: float)
```

---

## Signal Payloads

### `line_ready`

Emitted when an NPC card passes its input condition.

```gdscript
# line_data Dictionary keys:
{
    "card_id":       String,   # document_id of the card
    "collection_id": String,
    "entity_ref":    String,   # entity_name of the speaker
    "entity_label":  String,   # display name resolved from entity payload
    "line_mode":     String,   # "npc", "pc", "system", or "inherit"
    "line":          String,   # payload.data.line
    "base_ref":      String,   # "line" (or "" for system interstitials)
    "template_ref":  String,   # payload.template_ref
    "data":          Dictionary  # full payload.data for custom template props
}
```

### `choices_ready`

Emitted when a PC card's look-ahead is complete and at least one choice
passed its condition.

```gdscript
# choices is an Array of Dictionaries, one per candidate next card
# that passed its input_pin condition:
[
    {
        "index":         int,     # position in this array, for select_choice()
        "card_id":       String,
        "collection_id": String,
        "entity_ref":    String,  # should be the PC entity
        "line":          String,  # payload.data.line — the choice text
        "data":          Dictionary,
        "visited":       bool,    # true if this card_id is in the history_store set
        "card":          Dictionary  # full payload (not usually needed by UI)
    },
    ...
]
```

If zero choices pass their conditions (and there was at least one `line`
candidate that failed), the runtime logs an error and calls `_finish_dialogue()`,
emitting `dialogue_ended`. Game code should treat dialogue_ended as a signal
to clean up the UI.

### `dialogue_ended`

No payload. Emitted when the traversal reaches a terminal node.

A terminal node is one where:
- All output pins have empty connections, OR
- There are no output pins

### `choice_made`

Emitted when the player selects a choice, before the runtime advances to the
next card. Payload is the full card data of the selected choice card.

```gdscript
# card_data Dictionary keys — same shape as the line_ready payload:
{
    "card_id":       String,
    "collection_id": String,
    "entity_ref":    String,
    "entity_label":  String,
    "line_mode":     String,
    "line":          String,   # the choice text the player selected
    "base_ref":      String,
    "template_ref":  String,   # included here for template-driven dispatch
    "data":          Dictionary  # full payload.data
}
```

This signal exists for advanced users who want to implement logic keyed on
card template — for example, a class structure where each `template_ref`
maps to a handler that does something specific when that choice is made
(trigger an animation, update a quest log, etc.). The signal fires after
the choice is registered but before traversal continues, so handlers can
perform synchronous side effects safely.

Typical use:

```gdscript
TarinoiRuntime.choice_made.connect(func(card_data):
    match card_data["template_ref"]:
        "persuasion_attempt":
            QuestLog.record_persuasion_attempt(card_data["card_id"])
        "intimidation":
            PlayerStats.increment_intimidation_uses()
)
```

### `dialogue_error`

```gdscript
# message: String describing the error
```

Errors are non-fatal by default. The runtime emits the signal and stalls
in its current state. Game code can call `advance()` to attempt to continue
or `abort_dialogue()` to reset to IDLE.

```gdscript
func abort_dialogue() -> void   # resets state machine to IDLE, emits dialogue_ended
```

---

## Card Loading

Cards are loaded via `TarinoiDataAccess.load_card(collection_id, card_id)`.
The default (`TarinoiDataAccess.Sync`) runs the query synchronously on the
main thread and returns immediately. Call sites use `await` so that custom
async providers can be swapped in transparently; in the default implementation
the await resolves in the same frame.

```gdscript
# Effective query (via active_filter()):
SELECT payload FROM documents d
WHERE document_id = ? AND collection_id = ? AND <active_filter()>
```

---

## Entity Resolution

Entities are resolved from the in-memory `_entities` cache, populated at
`_load_global_cache()` time (on `configure()` and after every sync). Resolution
is O(1).

```gdscript
func _resolve_entity(entity_name: String) -> Dictionary:
    return _entities.get(entity_name, {})
```

Fields used by the runtime:
- `identifier` — canonical name, used as lookup key
- `label` — display name shown to client
- `is_player_character` — determines NPC vs PC flow

---

## Input Pin Condition Evaluation

Every card type (`line`, `blank`, `start`, `jump`) may carry an
`input_pin.condition` string. Evaluation happens at the start of
`_process_card`, before the card's `base_ref` is inspected.

```gdscript
var condition: String = card.get("input_pin", {}).get("condition", "")
if not condition.is_empty() and not _dispatcher.eval_condition(condition):
    # Card fails condition — treat it as transparent and follow its connections.
    _follow_connections(card, card_id, collection_id)
    return
```

`Dispatcher.eval_condition(expr: String) -> bool` accepts the raw expression
string. Parsing and AST caching are handled internally by the Dispatcher.
Empty string always returns true without parsing.

**For look-ahead (choice candidates):** each candidate's condition is evaluated
inside `_build_choices_from_targets`. Candidates that fail are silently
excluded from the choices array. If all candidates fail, `dialogue_ended` is
emitted (no choices available).

A card that fails its input condition is skipped by following its own output
connections. If skipping leads to a card already visited in this traversal,
`dialogue_error` is emitted to break the loop.

---

## Output Pin and Output Selector Resolution

Connection strings use the format `"pin_name>>target_card_id"`.
Observed pin names in real data: `default`, `pass`, `fail`.

### Classification logic

```gdscript
# Separate connections into default and named buckets
for conn in card.get("connections", []):
    var parts = conn.split(">>")
    var pin = parts[0]          # "default", "pass", "fail", …
    var target = parts[1]       # document_id of the next card

if named_pins.is_empty():
    # All connections are "default"
    if unique_targets.size() == 1:
        # Single output: follow it
    else:
        # Multiple outputs: look-ahead for PC choices (see above)
else:
    # Named pins: requires output_selector evaluation (Phase 3)
    # Phase 2: emit pin_choice_needed, wait for select_pin()
```

### Output Selector

When a card has named output pins, `output_selector` holds a serialised
function call expression evaluated by the Dispatcher:

```gdscript
var pin_name: String = _dispatcher.eval_call(ast)  # e.g. "pass" or "fail"
var target_id = named_pins[pin_name]
if target_id.is_empty():
    emit_signal("dialogue_error", "Switch mismatch on card %s" % card_id)
    return
```

### No Outputs / Empty Connections

```gdscript
if card.get("connections", []).is_empty():
    _state = State.IDLE
    emit_signal("dialogue_ended")
```

---

## PC Choice Look-Ahead

PC choices are **not** aggregated by a dedicated "choice node." Instead, any card
with multiple `default` output connections triggers look-ahead: each connected
card is a candidate choice.

### Look-ahead on multiple default connections

1. Collect the unique target card IDs from all `default` connections of the
   card just traversed.
2. Load each target card from SQLite.
3. Discard non-`"line"` base_ref candidates (silently).
4. Evaluate each remaining candidate's `input_pin.condition`.
5. Filter to passing candidates.
6. If one candidate remains: follow it directly (no choice UI).
7. If multiple: emit `choices_ready(passing_candidates)`.

On `select_choice(index)`:
- Emit `choice_made(card_data)` with the full card data of the selected card.
- Call `_follow_connections` on the selected card (follow *its* output
  connections to the next card).

### PC card reached singly

If a PC entity card (`is_player_character == true`) is reached via a single
connection (not through the multi-default look-ahead above), it is presented
as a single-option choice (one button). The player must confirm before
traversal continues. This handles "forced" player lines.

### Named output pins on PC cards

A PC entity card may have named output pins (`pass`, `fail`, etc.) instead of
a `default` connection. These represent skill-check or branching outcomes tied
to the choice the player just made. When an `output_selector` is present, the
runtime evaluates it and follows the returned pin automatically. When no
`output_selector` is set (or the named function is not bound), the runtime emits
`pin_choice_needed` and waits for `select_pin(pin_name)` — useful for developer
tooling and manual testing.

---

## Jump Cards

A `jump` card (`base_ref == "jump"`) has no `line` in `data`. Its purpose
is to redirect traversal to any card anywhere in the project.

```gdscript
# Jump card payload.data:
{
    "target": String   # the destination card's bare document_id
}
```

`target` is the jump base's one `card-link` property. It carries **no
collection component** and may point at a card on another board, so the runtime
resolves it with `TarinoiDataAccess.locate_card(card_id)`, which returns the
card together with the collection it lives in (`load_card` needs the collection
up front). A custom data provider must implement `locate_card` for jumps to
work.

On encountering a jump card: do not emit `line_ready`. Locate the target,
run the loop check on it, and continue traversal there. Jump cards are
transparent to the client. A dangling target — the card was deleted, or is
on the wrong layer — is reported through `dialogue_error`.

> The runtime used to expect a `target_collection_id` / `target_card_id` pair
> here. That shape never existed in the data; it came from a documentation
> error the app corrected on 2026-08-27. Any jump stopped the dialogue with
> "Jump card … has missing target" until this was fixed.

---

## Blank Cards

A `blank` card (`base_ref == "blank"`) has no `line` and no entity. It
may have an input condition. It is a structural node: evaluate its
condition (skip if false), then follow its output without emitting
`line_ready`.

Blank cards are transparent to the client.

---

## Card Function Evaluation

Any string value in `card.data` that begins with `Fn.` is a side-effect
expression to be evaluated via the Dispatcher.

### When to evaluate

| Card type | Trigger |
|-----------|---------|
| NPC line | Before `line_ready` is emitted — functions fire the moment the line is shown |
| PC choice | In `select_choice()` — functions fire for the *selected* card only; unchosen candidates are never evaluated |
| Blank / start / jump / unknown | In `_process_card()` before following connections |

### Evaluation order

Build an order index from `card.props` (`name → array position`). Collect
all `Fn.*` string values in `card.data`. Sort by props index; any key absent
from `props` sorts last. Evaluate in that order.

`card.props` is an ordering hint, not an exhaustive declaration — always
scan `card.data` directly rather than relying on `props` to enumerate what
is present.

### `Card.CurrentContextCard`

The expression parser supports `Card.CurrentContextCard` as a special
argument token. Before any output-selector or function call is dispatched,
the Dispatcher's context card is set to the current card's full payload
dictionary. Passing `Card.CurrentContextCard` in a function argument
delivers that dictionary at call time.

Standard pattern for skill-check cards:

```
output_selector: "Fn.global.CheckSkill(Card.CurrentContextCard)"
```

The function receives `card.data` (including `threshold`, `skill`, etc.)
without needing to know the card's ID.

### Error cases

- **Unbound function call** (expression parses but collection/method not
  registered): log error, continue — do not abort the dialogue.
- **Card has no connections and no `flow:end`**: log error and emit
  `dialogue_ended` (implicit termination; indicates missing authoring).
- **Card has connections that all fail to parse**: same as above.

### System line interstitial

A function called via `output_selector` may produce an informational
message that should be shown to the player before navigation continues
(e.g. "Rolled 6 against threshold 3 — Success!"). The runtime supports
a one-shot queue for this:

1. During `eval_call`, the function implementation calls
   `TarinoiRuntime.post_system_line(text)`.
2. After `eval_call` returns (with the pin name), the runtime checks the
   queue. If non-empty, it emits a `line_ready` with `line_mode: "system"`
   and a sentinel `card_id` of `"__system__"`, then stores the navigation
   target in `_pending_nav_target`.
3. When the player advances past the system line, the runtime navigates to
   the stored target.

The queue holds one line. If multiple calls to `post_system_line` occur in
one dispatch, only the first is shown.

---

## Threading Model

All SQLite reads are **synchronous on the main thread**. The godot-sqlite
addon does not require a background thread for the load sizes involved
(single card lookups, entity cache loads). No deferred dispatch is used.

---

## Visited Card Guard (Loop Detection)

```gdscript
var _visited: Dictionary = {}   # card_id → true

# Reset at start_dialogue() and after each line_ready / choices_ready.
# (Only reset at meaningful stops, not during silent card skipping.)

func _check_loop(card_id: String) -> bool:
    if _visited_in_traversal.has(card_id):
        emit_signal("dialogue_error", "Loop detected at card %s" % card_id)
        return true
    _visited_in_traversal[card_id] = true
    return false
```

---

## Visited-Choice History

The runtime supports optional tracking of which PC choice cards the player has
already selected, so UIs can dim previously-taken options.

**Opt-in:** assign a `TarinoiHistoryStore` to `TarinoiRuntime.history_store`
before calling `start_dialogue()`. If `null`, visited state is not tracked and
all choices carry `visited = false`.

**Lifecycle:**

| Event | Action |
|-------|--------|
| `start_dialogue(collection_id, card_id)` | Calls `history_store.get_visited(card_id)` and seeds `_session_visited_choices` |
| `select_choice(index)` | Adds chosen card_id to `_session_visited_choices` |
| `dialogue_ended` / `abort_dialogue()` | Calls `history_store.save_visited(start_card_id, visited_ids)` then emits |

All `dialogue_ended` emissions are consolidated through `_finish_dialogue()`,
which handles the flush before emitting.

**Default implementation:** `TarinoiHistoryStore.InMemory` (inner class in
`addons/tarinoi/core/history_store.gd`) stores visited sets in a Dictionary
and resets when freed. Provides within-session tracking without save-file
plumbing. Override `get_visited` / `save_visited` for persistence.

---

## Data Access

`TarinoiRuntime.data` is a `TarinoiDataAccess` instance
(`addons/tarinoi/core/data_access.gd`), populated at `configure()` time
and `null` before that.

```gdscript
# Get any document by its document_id (two-layer merge applied via active_filter)
var payload: Dictionary = TarinoiRuntime.data.get_document(document_id)
var payload: Dictionary = TarinoiRuntime.data.get_document(document_id, collection_id)

# Get an entity by its identifier (reads in-memory _entities cache, O(1))
var entity: Dictionary = TarinoiRuntime.data.get_entity("ferryman")
```

Both return `{}` if not found or called before `configure()`.

`get_document` uses `active_filter()` — two-layer merge semantics apply:
buffer-layer document beats main; inactive buffer suppresses main.

`get_entity` reads `TarinoiRuntime._entities`, the same cache used by the
dialogue engine. Covers all entities, not just `dialog_capable` ones.
Refreshed after every sync.

---

## Summary of Runtime Queries

| Operation | Table(s) | Filter | Notes |
|---|---|---|---|
| Load card | documents | document_id, collection_id, active_filter | `_load_card()` |
| Look-ahead (PC choices) | documents | document_id IN (...), active_filter | `_build_choices_from_targets()` |
| Get start cards | documents | base_ref = 'start', active_filter | `get_start_cards()` |
| Get document (data access) | documents | document_id [, collection_id], active_filter | `TarinoiDataAccess.get_document()` |
| Resolve entity | in-memory `_entities` | identifier lookup | `_resolve_entity()`, `TarinoiDataAccess.get_entity()` |
| Load entity cache | documents | document_type = 'entity', all layers | `_load_global_cache()` → `_merge_layers()` |
| Load collection cache | documents | document_type = 'collection-manifest', all layers | `_load_global_cache()` |
| Load list cache | documents | collection_id IN (...), all layers | `_load_global_cache()` |
