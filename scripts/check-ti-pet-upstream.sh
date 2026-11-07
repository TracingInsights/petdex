#!/usr/bin/env bash
# Fail when an upstream Petdex source that packages/ti-pet copied or adapted
# has changed since it was ported (hashes in packages/ti-pet/UPSTREAM.md).
# Run after merging crafter-station/petdex; a failure means: re-read the
# upstream diff, port what matters into ti-pet, then update the hash.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER="$ROOT/packages/ti-pet/UPSTREAM.md"
status=0

# Table rows: | ti-pet file | `upstream path` | how | `sha256` |
while IFS= read -r line; do
  path=$(printf '%s' "$line" | awk -F'|' '{print $3}' | tr -d ' `')
  how=$(printf '%s' "$line" | awk -F'|' '{print $4}' | tr -d ' ')
  want=$(printf '%s' "$line" | awk -F'|' '{print $5}' | tr -d ' `')
  [[ "$path" == packages/* && ${#want} -eq 64 ]] || continue
  if [[ ! -f "$ROOT/$path" ]]; then
    echo "check-ti-pet-upstream: $path is gone upstream" >&2
    status=1
    continue
  fi
  got=$(sha256sum "$ROOT/$path" | cut -d' ' -f1)
  if [[ "$got" != "$want" ]]; then
    echo "check-ti-pet-upstream: $path changed ($how in ti-pet): re-port, then update UPSTREAM.md" >&2
    status=1
  fi
done < "$LEDGER"

# A copied file must still be byte-identical to its upstream source.
if ! cmp -s "$ROOT/packages/petdex-desktop-native/src/sprite.zig" "$ROOT/packages/ti-pet/src/sprite.zig"; then
  echo "check-ti-pet-upstream: packages/ti-pet/src/sprite.zig differs from upstream's copy" >&2
  status=1
fi

[[ $status -eq 0 ]] && echo "check-ti-pet-upstream: ok"
exit $status
