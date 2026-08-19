# Tarinoi for Godot

Tarinoi dialogue for Godot 4. Syncs authored dialogue content from the Tarinoi service
into a local SQLite database, evaluates authored conditions and functions against your
game's own code, and plays dialogue back through a small signal-based runtime.

Requires the latest stable **Godot 4.x**.

> **Status: early development.** Version 0.1.0. The API is not stable yet and will change
> before 1.0.

## Installation

Search for **Tarinoi** in Godot's **AssetLib** tab and install it, along with
**Godot SQLite** (v4.7), which the plugin depends on. Then enable both under
**Project → Project Settings → Plugins**.

To install by hand instead, copy `addons/tarinoi/` into your project's `addons/`
directory.

## Documentation

The full guide — configuration, bindings, trigger nodes, replacing the dialogue UI,
shipping a build, and troubleshooting — lives at:

**https://tarinoi.app/docs/plugins/godot**

Related:

- [What the plugins do and don't do](https://tarinoi.app/docs/plugins/)
- [Writing your own integration](https://tarinoi.app/docs/plugins/writing_your_own) — the engine-agnostic data contract
- [Adapting a plugin](https://tarinoi.app/docs/plugins/adapting) — forking, porting, and the traps we hit

Implementation notes for this plugin specifically are in [`docs/technical/`](docs/technical/):
sync, importer, expression evaluation, codegen, and the runtime state machine.

## License

MIT — see [`LICENSE.md`](LICENSE.md). These plugins are reference implementations, meant
to be built on, modified, and incorporated into your own work.
