#!/usr/bin/env bash
#
# ai-harness — minimal sync CLI for the AI harness shared repo.
# v0.2 prototype (macOS / Linux; Windows ignored for now).
#
# Model:
#   - .agents/ is the canonical, tool-agnostic source of truth in each project.
#   - sync mirrors each bundle's full contents (skills/, agents/, rules/, and any
#     loose files) into .agents/.
#   - .cursor and .claude are SYMLINKS to .agents/, so every tool reads the
#     same content from its own expected path. No per-tool copies.
#
# Requires: bash 3.2+, git, yq, and shasum or sha256sum.
#   Install yq with: brew install yq
#
# Commands:
#   init    Create a starter .ai-harness.yml
#   sync    Fetch bundles, merge into .agents/, refresh tool symlinks
#   check   Verify .agents/ + symlinks match the lock (for CI)
#
set -euo pipefail

CONFIG_FILE=".ai-harness.yml"
LOCK_FILE=".ai-harness.lock"
AGENTS_DIR=".agents"

# Temp paths to remove on exit (global so the EXIT trap can see them).
CLEANUP=()
cleanup() {
  [[ ${#CLEANUP[@]} -eq 0 ]] && return 0
  local p; for p in "${CLEANUP[@]}"; do [[ -n "$p" ]] && rm -rf "$p"; done
}
trap cleanup EXIT

# --- hash command ------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
  HASH_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH_CMD="shasum -a 256"
else
  echo "Need either sha256sum or shasum installed." >&2; exit 1
fi
hash_file() { $HASH_CMD "$1" | awk '{print $1}'; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }
}

usage() {
  cat <<USAGE
ai-harness <command>

  init    Create a starter $CONFIG_FILE
  sync    Fetch bundles, merge into $AGENTS_DIR/, refresh tool symlinks
  check   Verify $AGENTS_DIR/ and symlinks match $LOCK_FILE (for CI)
USAGE
}

# --- init --------------------------------------------------------------
cmd_init() {
  [[ -f "$CONFIG_FILE" ]] && { echo "$CONFIG_FILE already exists." >&2; exit 1; }
  cat > "$CONFIG_FILE" <<'CFG'
# AI harness configuration
# version: a git tag in the ai-harness repo (e.g. v1.0.0)
# repo:    SSH or HTTPS URL of the ai-harness repo
# bundles: folders to pull; each is a partial .agents/ tree (skills/, agents/, rules/, ...)
# tools:   tool dirs to symlink to .agents/ (so each tool reads the same content)
version: v0.0.1
repo: git@bitbucket.org:YOUR_WORKSPACE/ai-harness.git
bundles:
  - shared
  - android/shared
tools:
  - cursor
  - claude
CFG
  echo "Created $CONFIG_FILE. Edit it, then run: ai-harness sync"
}

# --- config ------------------------------------------------------------
read_config() {
  require git; require yq
  [[ -f "$CONFIG_FILE" ]] || { echo "No $CONFIG_FILE. Run: ai-harness init" >&2; exit 1; }
  VERSION=$(yq -r '.version' "$CONFIG_FILE")
  REPO=$(yq -r '.repo' "$CONFIG_FILE")

  BUNDLES=()
  while IFS= read -r l; do [[ -n "$l" && "$l" != "null" ]] && BUNDLES+=("$l"); done \
    < <(yq -r '.bundles[]' "$CONFIG_FILE" 2>/dev/null || true)
  [[ ${#BUNDLES[@]} -gt 0 ]] || { echo "No bundles defined in $CONFIG_FILE." >&2; exit 1; }

  TOOLS=()
  while IFS= read -r l; do [[ -n "$l" && "$l" != "null" ]] && TOOLS+=("$l"); done \
    < <(yq -r '.tools[]' "$CONFIG_FILE" 2>/dev/null || true)
}

# Managed file paths recorded in the lock (one per line).
locked_files() {
  [[ -f "$LOCK_FILE" ]] || return 0
  awk '/^files:/{f=1;next} /^[^ ]/{f=0} f && /path:/{print $3}' "$LOCK_FILE"
}

# Print "path<TAB>sha" for every file under a dir.
hash_tree() {
  local dir="$1"; [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' file; do
    printf '%s\t%s\n' "$file" "$(hash_file "$file")"
  done < <(find "$dir" -type f -print0 | sort -z)
}

# --- sync --------------------------------------------------------------
cmd_sync() {
  read_config
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/ai-harness.XXXXXX")
  CLEANUP+=("$tmp")

  echo "Fetching $REPO at $VERSION ..."
  git clone --quiet -c advice.detachedHead=false --depth 1 --branch "$VERSION" "$REPO" "$tmp/repo"

  # 1. Stage merged content (.agents/<type>/...), detecting collisions.
  local stage="$tmp/stage"; mkdir -p "$stage/$AGENTS_DIR"
  local manifest="$tmp/manifest"; : > "$manifest"   # "relpath<TAB>bundle"

  local bundle src file rel target prev
  for bundle in "${BUNDLES[@]}"; do
    src="$tmp/repo/$bundle"
    [[ -d "$src" ]] || { echo "Bundle not found at $VERSION: $bundle" >&2; exit 1; }
    # A bundle mirrors into .agents/. Everything inside the bundle ships, at any
    # depth: typed folders (skills/, agents/, rules/, ...) AND loose root files.
    # Docs that should NOT ship belong outside the bundle folders (repo root or
    # a top-level docs/). The repo's .gitignore keeps OS junk out of git.
    while IFS= read -r -d '' file; do
      rel="${file#$src/}"
      target="$stage/$AGENTS_DIR/$rel"
      if [[ -e "$target" ]]; then
        prev=$(awk -F'\t' -v k="$rel" '$1==k{print $2; exit}' "$manifest")
        echo "Collision: '$rel' provided by both '$prev' and '$bundle'." >&2
        echo "Rename one, or consolidate it into a shared bundle." >&2
        exit 1
      fi
      mkdir -p "$(dirname "$target")"
      cp "$file" "$target"
      printf '%s\t%s\n' "$rel" "$bundle" >> "$manifest"
    done < <(find "$src" -type f -print0)
  done

  # 2. Remove orphans: files we managed before that are no longer present.
  local oldlist newlist; oldlist=$(mktemp); newlist=$(mktemp)
  locked_files | sort > "$oldlist"
  ( cd "$stage" && find "$AGENTS_DIR" -type f 2>/dev/null ) | sort > "$newlist"
  comm -23 "$oldlist" "$newlist" | while IFS= read -r orphan; do
    [[ -n "$orphan" ]] && rm -f "$orphan"
  done
  rm -f "$oldlist" "$newlist"

  # 3. Apply staged content into the real .agents/ (managed files only;
  #    locally-added files not in the lock are left untouched).
  mkdir -p "$AGENTS_DIR"
  ( cd "$stage" && find "$AGENTS_DIR" -type f ) | while IFS= read -r rel; do
    mkdir -p "$(dirname "$rel")"; cp "$stage/$rel" "$rel"
  done
  find "$AGENTS_DIR" -type d -empty -delete 2>/dev/null || true
  mkdir -p "$AGENTS_DIR"

  # 4. Ensure tool symlinks point at .agents/.
  local linked=() tool link
  for tool in "${TOOLS[@]}"; do
    link=".$tool"
    if [[ -L "$link" ]]; then
      ln -snf "$AGENTS_DIR" "$link"
    elif [[ -e "$link" ]]; then
      echo "Skipping $link: exists as a real file/dir, not a symlink. Remove it" >&2
      echo "manually if you want the CLI to manage it." >&2
      continue
    else
      ln -s "$AGENTS_DIR" "$link"
    fi
    linked+=("$link -> $AGENTS_DIR")
  done

  # 5. Write the lock.
  {
    echo "# Generated by ai-harness. Do not edit."
    echo "version: $VERSION"
    echo "repo: $REPO"
    echo "bundles:"; for b in "${BUNDLES[@]}"; do echo "  - $b"; done
    echo "symlinks:"
    if [[ ${#linked[@]} -gt 0 ]]; then for s in "${linked[@]}"; do echo "  - $s"; done; fi
    echo "files:"
    hash_tree "$AGENTS_DIR" | while IFS=$'\t' read -r path sha; do
      printf '  - path: %s\n    sha256: %s\n' "$path" "$sha"
    done
  } > "$LOCK_FILE"

  echo "Sync complete. Content in $AGENTS_DIR/ ; symlinks: ${TOOLS[*]:-none}."
  echo "Review with: git status && git diff"
}

# --- check -------------------------------------------------------------
cmd_check() {
  read_config
  [[ -f "$LOCK_FILE" ]] || { echo "No $LOCK_FILE — run sync first." >&2; exit 1; }
  local rc=0

  local current locked; current=$(mktemp); locked=$(mktemp)
  CLEANUP+=("$current" "$locked")
  hash_tree "$AGENTS_DIR" | sort > "$current"
  awk '
    /^files:/{f=1;next} /^[^ ]/{f=0}
    f && /path:/{p=$3}
    f && /sha256:/{print p"\t"$2}
  ' "$LOCK_FILE" | sort > "$locked"

  if ! diff -q "$locked" "$current" >/dev/null; then
    echo "Drift in $AGENTS_DIR/ — managed content does not match the lock:" >&2
    diff "$locked" "$current" >&2 || true
    rc=1
  fi

  local tool link
  for tool in "${TOOLS[@]}"; do
    link=".$tool"
    if [[ ! -L "$link" ]]; then
      echo "Missing or non-symlink: $link (expected -> $AGENTS_DIR)" >&2; rc=1
    elif [[ "$(readlink "$link")" != "$AGENTS_DIR" ]]; then
      echo "Wrong target: $link -> $(readlink "$link") (expected $AGENTS_DIR)" >&2; rc=1
    fi
  done

  if [[ $rc -eq 0 ]]; then
    echo "OK — $AGENTS_DIR/ and symlinks match $LOCK_FILE."
  else
    echo "Run 'ai-harness sync' to restore managed state." >&2
  fi
  exit $rc
}

# --- entry -------------------------------------------------------------
case "${1:-help}" in
  init)  cmd_init ;;
  sync)  cmd_sync ;;
  check) cmd_check ;;
  help|--help|-h) usage ;;
  *) echo "Unknown command: ${1:-}" >&2; usage >&2; exit 1 ;;
esac