#!/bin/bash
# GPU client windows (alacritty, chromium...) get mapped but don't render
# under virtio-gpu/virgl: only clients using shared-memory buffers (foot)
# render correctly. Confirmed that these do NOT fix it:
#   - AQ_NO_MODIFIERS=1            (was already active)
#   - render:explicit_sync         (removed in Hyprland 0.56)
#   - render:cm_enabled = false    (tried, no change)
# What does work: LIBGL_ALWAYS_SOFTWARE=1, which makes Mesa use llvmpipe and
# clients deliver wl_shm buffers. GL acceleration inside the VM is lost, but
# the desktop is usable. To revert once Mesa/Hyprland fix this, just delete
# the line from /etc/environment.d/90-vm-graphics.conf
set -uo pipefail
log() { echo ""; echo "==> $*"; }

log "LIBGL_ALWAYS_SOFTWARE in the session environment"
sudo tee /etc/environment.d/90-vm-graphics.conf >/dev/null <<'EOF'
# virtio-gpu (virgl) under UTM/QEMU
WLR_NO_HARDWARE_CURSORS=1
AQ_NO_MODIFIERS=1
WLR_RENDERER_ALLOW_SOFTWARE=1
# GPU clients don't deliver composable buffers under virgl: their windows
# stay black. With llvmpipe they use wl_shm and render correctly.
LIBGL_ALWAYS_SOFTWARE=1
EOF
cat /etc/environment.d/90-vm-graphics.conf

log "looknfeel: no blur (expensive with software rendering)"
cat > ~/.config/hypr/looknfeel.lua <<'LUA'
-- VM settings: rendering goes through llvmpipe (see 90-vm-graphics.conf),
-- so blur is expensive. Without it, the desktop stays smooth.
hl.config({
  decoration = {
    blur = { enabled = false },
    shadow = { enabled = false },
  },
})
LUA

log "rebooting so the whole session tree inherits the environment"
sync
sudo systemctl reboot
