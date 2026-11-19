#!/usr/bin/env bash
# Applies MFS patches to pinned submodules. Safe to re-run: already-applied patches are skipped.
set -euo pipefail

cd "$(dirname "$0")/.."

apply() {
  local submodule="$1" patch
  patch="$(pwd)/patches/$2"
  if git -C "$submodule" apply --check "$patch" 2>/dev/null; then
    git -C "$submodule" apply "$patch"
    echo "Applied $2 to $submodule"
  elif git -C "$submodule" apply --reverse --check "$patch" 2>/dev/null; then
    echo "Already applied: $2"
  else
    echo "Cannot apply $2 to $submodule (pin changed?)" >&2
    exit 1
  fi
}

# Dexcom Stelo advertises as DX01; upstream G7SensorKit only connects to DXCM and DX02.
apply G7SensorKit G7SensorKit-stelo.patch
