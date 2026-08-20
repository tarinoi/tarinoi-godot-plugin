#!/usr/bin/env bash
#
# Builds a distributable zip of the Tarinoi Godot plugin.
#
#   tools/make_release_zip.sh            → addons only (for manual install / AssetLib)
#   tools/make_release_zip.sh --full     → the whole project, tests and docs included
#
# The file list comes from `git ls-files`, so anything gitignored — .godot/,
# addons/gut/, the iOS godot-sqlite binaries, credentials, bundled snapshots —
# is excluded by construction. macOS .DS_Store files are then stripped again
# explicitly, belt and braces: Finder recreates them constantly, and one riding
# along in a published zip looks sloppy.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODE="addons"
if [[ "${1:-}" == "--full" ]]; then
    MODE="full"
elif [[ $# -gt 0 ]]; then
    echo "usage: $(basename "$0") [--full]" >&2
    exit 2
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: not a git repository — this script builds the file list from git" >&2
    exit 1
fi

VERSION="$(sed -n 's/^version="\(.*\)"$/\1/p' addons/tarinoi/plugin.cfg)"
if [[ -z "$VERSION" ]]; then
    echo "error: could not read version from addons/tarinoi/plugin.cfg" >&2
    exit 1
fi

OUT_DIR="$REPO_ROOT/dist"
# Distinct names: the two modes produce genuinely different artifacts and one
# must not silently overwrite the other.
if [[ "$MODE" == "addons" ]]; then
    OUT="$OUT_DIR/tarinoi-godot-plugin-v${VERSION}.zip"
else
    OUT="$OUT_DIR/tarinoi-godot-plugin-v${VERSION}-project.zip"
fi
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Warn rather than fail: building a test zip from a dirty tree is legitimate.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "warning: working tree has uncommitted changes; they are included in the zip" >&2
fi

# "." in full mode rather than an empty array: bash 3.2, which is what macOS
# ships, treats an unset empty array as an unbound variable under `set -u`.
if [[ "$MODE" == "addons" ]]; then
    PATHSPEC=(addons README.md LICENSE.md CHANGELOG.md)
else
    PATHSPEC=(.)
fi

echo "Collecting files…"
COUNT=0
while IFS= read -r -d '' f; do
    # Skip files that are tracked but no longer on disk (deleted, not yet committed).
    [[ -e "$f" ]] || continue
    mkdir -p "$STAGE/$(dirname "$f")"
    cp -Pp "$f" "$STAGE/$f"
    COUNT=$((COUNT + 1))
done < <(git ls-files -z -- "${PATHSPEC[@]}")

if [[ "$COUNT" -eq 0 ]]; then
    echo "error: no files collected" >&2
    exit 1
fi

# macOS shenanigans: strip .DS_Store and AppleDouble/resource-fork leftovers.
find "$STAGE" \( -name '.DS_Store' -o -name '._*' -o -name '.AppleDouble' \) -exec rm -rf {} + 2>/dev/null || true

mkdir -p "$OUT_DIR"
rm -f "$OUT"

echo "Writing $OUT…"
(
    cd "$STAGE"
    # -X drops extended attributes and Finder metadata that macOS zip adds by default.
    zip -qXr "$OUT" .
)

# Fail loudly if anything unwanted still made it in, rather than shipping it.
if unzip -l "$OUT" | grep -qE '\.DS_Store|__MACOSX|/\._'; then
    echo "error: macOS metadata found in $OUT" >&2
    unzip -l "$OUT" | grep -E '\.DS_Store|__MACOSX|/\._' >&2
    exit 1
fi

echo
echo "Built $(basename "$OUT") — $COUNT files, $(du -h "$OUT" | cut -f1)"
echo "Mode: $MODE (version $VERSION)"
