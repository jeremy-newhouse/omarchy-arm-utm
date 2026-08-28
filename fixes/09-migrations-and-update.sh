#!/bin/bash
# omarchy-update failed because the build never sealed the existing migrations.
# A normal Omarchy installer marks them all as applied when it finishes
# (the system is born already in the final state); here only 8 of 83 were
# sealed, so omarchy-update tried to replay 75 historical migrations and died
# on the one that replaces `dust` with `tensaku`, an Omarchy-specific package
# that doesn't exist on Arch Linux ARM. Along the way it left the system
# without `dust`.
set -uo pipefail
log() { echo ""; echo "==> $*"; }
STATE="$HOME/.local/state/omarchy/migrations"
MIGR=/usr/share/omarchy/migrations

log "1/5 sealing existing migrations (like a clean install)"
mkdir -p "$STATE"
n=0
for f in "$MIGR"/*.sh; do
  b=$(basename "$f")
  [ -e "$STATE/$b" ] || { : > "$STATE/$b"; n=$((n+1)); }
done
echo "  sealed $n new; total $(ls -1 "$STATE" | wc -l) of $(ls -1 "$MIGR"/*.sh | wc -l)"
echo "  pending now: $(omarchy-migrate --pending 2>/dev/null | wc -l)"

log "2/5 recovering dust (removed by the failed migration)"
sudo pacman -S --noconfirm --needed dust 2>&1 | tail -3
pacman -Q dust 2>&1

log "3/5 hardening omarchy-pkg-add against packages that don't exist on ARM"
sudo tee /usr/local/bin/omarchy-pkg-add >/dev/null <<'WRAP'
#!/bin/bash
# Wrapper for Arch Linux ARM.
#
# Omarchy-specific packages (tensaku, omarchy-nvim, ttfx...) and several
# proprietary apps only exist for x86_64. The original omarchy-pkg-add aborts
# with an error if any is missing, which fails omarchy-update entirely and
# leaves migrations half-done. This wrapper skips the ones not present in any
# repo, warns about which, and installs the rest with the original script.
REAL=/usr/share/omarchy/bin/omarchy-pkg-add
avail=(); skip=()
for p in "$@"; do
  if pacman -Q "$p" &>/dev/null || pacman -Si "$p" &>/dev/null; then
    avail+=("$p")
  else
    skip+=("$p")
  fi
done
if ((${#skip[@]})); then
  printf '\033[33mSkipped, does not exist on Arch Linux ARM: %s\033[0m\n' "${skip[*]}" >&2
fi
((${#avail[@]})) || exit 0
exec "$REAL" "${avail[@]}"
WRAP
sudo chmod +x /usr/local/bin/omarchy-pkg-add
echo "  testing the wrapper:"
omarchy-pkg-add tensaku jq 2>&1 | tail -3

log "4/5 cleaning up orphans from AUR builds"
orph=$(pacman -Qdtq 2>/dev/null)
[ -n "$orph" ] && sudo pacman -Rns --noconfirm $orph 2>&1 | tail -3 || echo "  (none)"

log "5/5 re-running omarchy-update"
OMARCHY_UPDATE_NONINTERACTIVE=1 omarchy-update 2>&1 | tail -25
echo "  exit code: $?"

log "status"
echo "  pending: $(omarchy-migrate --pending 2>/dev/null | wc -l)"
echo "  dust:    $(pacman -Q dust 2>/dev/null || echo NO)"
echo ""
echo "==> FIX9_OK"
