# Tarinoi Godot Plugin — Getting Started

This guide walks you through setting up the Tarinoi plugin in a new Godot project, from installation to your first playable dialogue.

---

## 1. Prerequisites

- Godot 4.x
- A Tarinoi project with at least one start card
- Either:
  - A Tarinoi API key (for API sync), or
  - A GitLab personal access token scoped to `read_repository` (for Git sync)

---

## 2. Install

The plugin depends on two third-party addons that must be present alongside it.

**godot-sqlite** (required) — SQLite wrapper used to store and query synced dialogue content locally.
Install from the Godot Asset Library (search "Godot SQLite") or copy `addons/godot-sqlite/` from this repository. The plugin is tested against version 4.7.

**Gut** (optional) — unit testing framework, only needed if you want to run the plugin's test suite. Not required for normal use. Install from the Asset Library or copy `addons/gut/` from this repository (version 9.6.0).

Copy the `addons/tarinoi/` folder from this repository into your project's `addons/` directory. Your project should end up with:

```
your_project/
  addons/
    tarinoi/
      plugin.cfg
      plugin.gd
      autoload/
      core/
      nodes/
      scenes/
```

Enable the plugin in **Project > Project Settings > Plugins** — find "Tarinoi" and set it to **Active**.

If prompted to restart the editor, do so.

---

## 3. Configure

Open **Project > Project Settings** and find the **Tarinoi** section.

**For API sync (recommended for active development):**

| Setting | Value |
|---------|-------|
| `sync_source` | `api` |
| `api_path` | Your project's API URL, e.g. `https://api.tarinoi.com/projects/YOUR_PROJECT_ID/documents` |

Then set your API key via **Tools > Tarinoi: Set Tarinoi API token…**

**For Git sync:**

| Setting | Value |
|---------|-------|
| `sync_source` | `git` |
| `repo_url` | Your project's GitLab repository URL |

Then set your access token via **Tools > Tarinoi: Set Git access token…**

---

## 4. Sync content

Pull your Tarinoi content into the local database:

**Tools > Tarinoi: Clone / Sync**

Watch the Output panel — a successful sync logs `Tarinoi: sync complete`. If sync fails, check your API/Git URL and credentials in Project Settings.

---

## 5. Initialize

Create the quickstart scene:

**Tools > Tarinoi: Initialize project**

This creates two files:

- `res://tarinoi_quickstart.tscn` — a ready-to-run scene with the card picker and dialogue UI
- `res://tarinoi_quickstart.gd` — a stub script where you'll register your game's bindings

---

## 6. Run

Set `res://tarinoi_quickstart.tscn` as your main scene:

**Project > Project Settings > Application > Run > Main Scene**

Press **Play (F5)**. You should see a list of start cards from your Tarinoi project. Click one to play the dialogue.

---

## 7. Adding to your own scene

Once you've verified the quickstart works, you'll want to trigger dialogues from within your game scenes. The plugin provides trigger nodes for this.

### 3D scenes — `DialogueTrigger`

```
MyScene (Node3D)
└── Intercom (DialogueTrigger)   ← set collection_id / card_id in Inspector
    ├── CollisionShape3D
    └── MeshInstance3D
```

In your player or scene controller:

```gdscript
# When the player presses E near the trigger:
intercom.activate()

# Connect the signal to start dialogue:
intercom.interaction_triggered.connect(func(col_id, card_id):
    TarinoiRuntime.start_dialogue(col_id, card_id)
)
```

**Editor helper:** leave `collection_id` and `card_id` empty and open the scene — the Output panel prints all available start card IDs so you can copy the right pair into the Inspector.

### 2D scenes — `DialogueTrigger2D`

Same API as `DialogueTrigger`, but extends `Area2D`:

```gdscript
intercom_2d.interaction_triggered.connect(func(col_id, card_id):
    TarinoiRuntime.start_dialogue(col_id, card_id)
)
```

---

## 8. Registering bindings

Bindings wire the function and variable names in your Tarinoi project to GDScript implementations. Without bindings the dialogue runs but conditions are always false.

Open `res://tarinoi_quickstart.gd` and fill in `_setup_bindings()`:

```gdscript
extends "res://addons/tarinoi/scenes/tarinoi_quickstart.gd"

func _setup_bindings() -> void:
    var vars := MyVariables.new()
    TarinoiRuntime.registry.bind_variable_collection("global", vars)
    TarinoiRuntime.registry.bind_function_collection("global", MyFunctions.new(vars))
```

For a quick-start project without custom bindings, use **Tools > Tarinoi: Regenerate Bindings** to generate stub classes, then implement the function bodies.

See `demo/bindings/impl/global_functions.gd` and `game_variables.gd` in the demo for a complete working example.

---

## 9. Swapping the dialogue UI

The quickstart uses `TarinoiDialogueStrip` — a scrolling feed panel. To use your own UI instead:

1. Open your scene (or `res://tarinoi_quickstart.tscn`) in the editor.
2. Delete the `DialogueStrip` child node.
3. Add your own `Control` as a child instead.
4. Connect `TarinoiRuntime` signals to your UI:

```gdscript
TarinoiRuntime.line_ready.connect(_on_line_ready)
TarinoiRuntime.choices_ready.connect(_on_choices_ready)
TarinoiRuntime.dialogue_ended.connect(_on_dialogue_ended)
TarinoiRuntime.pin_choice_needed.connect(_on_pin_choice_needed)  # dev only
```

Signal payloads:

| Signal | Argument | Shape |
|--------|----------|-------|
| `line_ready` | `line_data: Dictionary` | `{line, entity_label, line_mode, card_id, collection_id, data}` |
| `choices_ready` | `choices: Array` | Array of `{line, card_id, collection_id, entity_ref, data}` |
| `dialogue_ended` | — | — |
| `pin_choice_needed` | `pin_names: Array` | Array of pin name strings (dev mode only) |

To advance past an NPC line: `TarinoiRuntime.advance()`

To select a player choice: `TarinoiRuntime.select_choice(index)` (0-based)

---

## 10. Next steps

- `docs/plugin/plugin_developer_guide.md` — full contract for the data model and graph traversal
- `demo/demo_3d.gd` — complete example of a scene that triggers dialogue from a 3D interactable
- `demo/choose_start.tscn` — runnable scene for testing any start card (run it directly with F6)
