# Tarinoi for Godot

Tarinoi dialogue for Godot 4. Syncs authored dialogue content from the Tarinoi service
into a local SQLite database, evaluates authored conditions and functions against your
game's own code, and plays dialogue back through a small signal-based runtime.

Requires the latest stable **Godot 4.x**.

> **Status: early development.** Version 0.1.0. The API is not stable yet and will change
> before 1.0.

## Installation

Download `tarinoi-godot-plugin-v0.1.0.zip` from the
[latest release](https://github.com/tarinoi/tarinoi-godot-plugin/releases/latest),
copy both `addons/tarinoi/` and `addons/godot-sqlite/` out of it into your
project's `addons/` directory, then enable **Tarinoi** and **Godot SQLite**
under **Project → Project Settings → Plugins**.

Cloning this repository works too — the release zip is the same `addons/`
content without the test suite, internal notes and build tooling.

The plugin stores content in a local SQLite database, so it depends on
[godot-sqlite](https://github.com/2shady4u/godot-sqlite). That dependency is
vendored here with prebuilt binaries for **macOS, Windows, Linux, Android and
web** — nothing extra to install for those targets.

**Exporting to iOS?** The iOS binaries are 286 MB of xcframeworks, too large to
vendor, so they are not in this repository. Install godot-sqlite from the Asset
Library or from its
[GitHub releases](https://github.com/2shady4u/godot-sqlite/releases) and let it
overwrite `addons/godot-sqlite/`, which restores the missing
`bin/*.ios.*` files. Every other platform works as shipped.

On Windows, SmartScreen may block the downloaded `.dll`. Right-click it,
choose **Properties**, and tick **Unblock**.

## Documentation

The full guide — configuration, bindings, trigger nodes, replacing the dialogue UI,
shipping a build, and troubleshooting — lives at:

**https://tarinoi.app/docs/plugins/godot.html**

Related:

- [What the plugins do and don't do](https://tarinoi.app/docs/plugins/)
- [Writing your own integration](https://tarinoi.app/docs/plugins/writing_your_own.html) — the engine-agnostic data contract
- [Adapting a plugin](https://tarinoi.app/docs/plugins/adapting.html) — forking, porting, and the traps we hit

Implementation notes for this plugin specifically are in [`docs/technical/`](docs/technical/):
API sync, the local database, expression evaluation, codegen, and the runtime
state machine.

Release history is in [`CHANGELOG.md`](CHANGELOG.md).

## Development

The test suite in [`test/`](test/) runs on
[GUT](https://github.com/bitwes/Gut), which is **not** bundled — it is a test
framework, not part of the plugin, and there is no reason to ship it to
everyone who installs Tarinoi. To run the tests, install **GUT** from the Asset
Library, enable it under **Project → Project Settings → Plugins**, and then
either use the GUT panel in the editor or run:

```
godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/ -ginclude_subdirs -gexit
```

Two importer tests need a live server and are skipped in headless mode; run
them from the editor with an API token configured if you want to exercise the
real feed.

## License

MIT — see [`LICENSE.md`](LICENSE.md). These plugins are reference implementations, meant
to be built on, modified, and incorporated into your own work.
