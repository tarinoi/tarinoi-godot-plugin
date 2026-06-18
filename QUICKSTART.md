# Tarinoi Godot Plugin — Quickstart

Get from zero to a running dialogue in under 10 minutes.

**Prerequisites:** Godot 4.x · A Tarinoi project with at least one start card · A Tarinoi API key or GitLab read token

---

## 1. Install godot-sqlite

The plugin stores content in a local SQLite database and requires the **godot-sqlite** extension (v4.7).

**Easiest:** search for "Godot SQLite" in the **Asset Library** tab inside Godot and install it — this includes the prebuilt binaries for your platform.

**From source:** copy `addons/godot-sqlite/` from this repository into your project, then download the matching platform binaries from [godot-sqlite releases](https://github.com/2shady4u/godot-sqlite/releases/tag/v4.7) and place them in `addons/godot-sqlite/bin/`.

---

## 2. Copy the plugin

Copy `addons/tarinoi/` from this repository into your project's `addons/` directory:

```
your_project/
  addons/
    godot-sqlite/       ← from step 1
    tarinoi/            ← from this repo
      plugin.cfg
      plugin.gd
      autoload/
      core/
      nodes/
      scenes/
```

---

## 3. Enable plugins

Open **Project > Project Settings > Plugins**.

Enable both **Godot SQLite** and **Tarinoi**. If Godot prompts you to restart the editor, do so.

---

## 4. Configure

Open **Project > Project Settings** and scroll to the **Tarinoi** section.

**API sync (recommended):**

| Setting | Value |
|---------|-------|
| `tarinoi/sync_source` | `api` |
| `tarinoi/api_path` | Your documents URL — copy it from Tarinoi's project settings |

Set your API key: **Tools > Tarinoi: Set Tarinoi API token…**

**Git sync:**

| Setting | Value |
|---------|-------|
| `tarinoi/sync_source` | `git` |
| `tarinoi/repo_url` | Your Tarinoi project's GitLab clone URL |

Set your access token: **Tools > Tarinoi: Set Git access token…**

---

## 5. Sync

**Tools > Tarinoi: Clone / Sync**

Watch the Output panel — a successful sync ends with `Tarinoi: sync complete`. If it fails, double-check your URL and credentials.

---

## 6. Initialize

**Tools > Tarinoi: Initialize project**

This creates:

- `res://tarinoi_quickstart.tscn` — ready-to-run scene with the card picker and dialogue UI
- `res://tarinoi_quickstart.gd` — stub script for registering your game's bindings

---

## 7. Run

**Project > Project Settings > Application > Run > Main Scene** → set to `res://tarinoi_quickstart.tscn`

Press **Play (F5)**. You should see a list of start cards from your Tarinoi project. Click one — dialogue plays.

---

## Next steps

- **[docs/getting-started.md](docs/getting-started.md)** — trigger nodes, dialogue UI, registering bindings, custom scenes
- **[docs/developer-guide.md](docs/developer-guide.md)** — full plugin contract: data model, graph traversal, expression evaluation
