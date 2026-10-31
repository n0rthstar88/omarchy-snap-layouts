#!/bin/bash
# Build the hyprbars title bar plugin for the running Hyprland and load it.
# Run this after a Hyprland update if a red "[hyprbars] ... Version mismatch"
# notification appears and the title bars are gone.
#
# Hyprbars stops Hyprland's mouse binds from seeing a title bar drag, so this
# adds hyprbars:dragstart and hyprbars:dragend events for Snap Layouts. They go
# right after hyprbars' own "Dragging initiated" and "Dragging ended" log lines
# rather than through a patch file, so rewording nearby code doesn't break them.
# If they can't be added or won't compile, it builds plain title bars and warns.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: rebuild-hyprbars.sh [--check | --build-only]

  (no option)    Build, install and load the plugin
  --check        Only show whether the events can be added; builds nothing
  --build-only   Build and install, but don't load the plugin

Environment:
  HYPRBARS_DEST    Install folder (default: ~/.local/lib/hyprland)
  HYPRBARS_COMMIT  hyprland-plugins commit to use instead of looking one up
  HYPRBARS_REPO    Source repo (default: the official hyprland-plugins)
USAGE
}

mode=install
case ${1:-} in
  "") ;;
  --check) mode=check ;;
  --build-only) mode=build ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

dest="${HYPRBARS_DEST:-$HOME/.local/lib/hyprland}"
repo="${HYPRBARS_REPO:-https://github.com/hyprwm/hyprland-plugins.git}"
work=$(mktemp -d -t hyprbars-XXXXXX)
trap 'rm -rf "$work"' EXIT
src="$work/hyprland-plugins"
log="$work/build.log"
file=hyprbars/barDeco.cpp

add_events() {
  awk '
    !included && /^#include/ {
      print
      print "#include <hyprland/src/managers/EventManager.hpp>"
      included = 1
      next
    }
    {
      print
      match($0, /^[[:space:]]*/)
      indent = substr($0, 1, RLENGTH)
      if ($0 ~ /"\[hyprbars\] Dragging initiated on.*;[[:space:]]*$/)
        print indent "g_pEventManager->postEvent(SHyprIPCEvent{\"custom\", \"hyprbars:dragstart\"});"
      else if ($0 ~ /"\[hyprbars\] Dragging ended on.*;[[:space:]]*$/)
        print indent "g_pEventManager->postEvent(SHyprIPCEvent{\"custom\", \"hyprbars:dragend\"});"
    }
  ' "$file" >"$work/barDeco.cpp"
  cp "$work/barDeco.cpp" "$file"
  grep -q 'hyprbars:dragstart' "$file" && grep -q 'hyprbars:dragend' "$file"
}

no_drag_warning() {
  echo "WARNING: $1; building plain title bars." >&2
  echo "Title bars will work, but dragging one won't open the Snap Layouts picker." >&2
}

git clone -q "$repo" "$src"
cd "$src"

hypr_commit=$(hyprctl -j version | jq -r '.commit')
hypr_tag=$(hyprctl -j version | jq -r '.tag')
commit="${HYPRBARS_COMMIT:-}"
# hyprpm.toml lists which hyprland-plugins commit suits each Hyprland release.
if [[ -z $commit && -f hyprpm.toml ]]; then
  commit=$(grep -F "\"$hypr_commit\"" hyprpm.toml | head -1 | grep -oE '[0-9a-f]{40}' | sed -n 2p || true)
fi
if [[ -n $commit ]]; then
  git checkout -q "$commit"
else
  echo "No hyprland-plugins commit listed for Hyprland $hypr_tag; using the latest." >&2
fi
echo "Using hyprland-plugins $(git rev-parse --short HEAD) for Hyprland $hypr_tag."

events=yes
if ! add_events; then
  events=no
  git checkout -q -- "$file"
fi

if [[ $mode == check ]]; then
  if [[ $events == yes ]]; then
    git --no-pager diff -U0 -- "$file" | grep '^+[^+]' || true
    echo "The drag events can be added."
    exit 0
  fi
  echo "The drag events can't be added: hyprbars' log lines have changed." >&2
  exit 1
fi

[[ $events == yes ]] || no_drag_warning "the drag events can't be added"

if ! make -C hyprbars >"$log" 2>&1; then
  if [[ $events == no ]]; then
    tail -20 "$log" >&2
    exit 1
  fi
  no_drag_warning "the drag events don't compile on this version"
  tail -20 "$log" >&2
  events=no
  git checkout -q -- "$file"
  if ! make -C hyprbars >"$log" 2>&1; then
    tail -20 "$log" >&2
    exit 1
  fi
fi

mkdir -p "$dest"
cp hyprbars/hyprbars.so "$dest/libhyprbars.so.new"

if [[ $mode == build ]]; then
  mv "$dest/libhyprbars.so.new" "$dest/libhyprbars.so"
  echo "Installed $dest/libhyprbars.so (drag events: $events). Not loaded."
  exit 0
fi

# A config reload won't reload a plugin path that is already registered, so
# swap the running copy and load it explicitly.
hyprctl plugin unload "$dest/libhyprbars.so" >/dev/null 2>&1 || true
mv "$dest/libhyprbars.so.new" "$dest/libhyprbars.so"
hyprctl plugin load "$dest/libhyprbars.so" >/dev/null

echo "Installed and loaded $dest/libhyprbars.so (drag events: $events)."
echo "If the title bars still don't show, log out and back in."
