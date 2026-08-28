# Omarchy on Arch Linux ARM — UTM image for Apple Silicon

Image built with
[`build-omarchy-arm.sh`](https://github.com/ggalancs/omarchy-arm-utm).

**Native aarch64** virtual machine (HVF-accelerated, no emulation) with
Arch Linux ARM + Hyprland and the configuration, themes and tooling of
[Omarchy 4](https://omarchy.org).

## Requirements

- Mac with Apple Silicon (M1 or later)
- [UTM](https://mac.getutm.app) 4.7 or later
- ~11 GB free disk: the `.zip` takes 3.6 GB and the uncompressed image
  another 7.2 GB, plus whatever it grows by in use

## Installation

1. Unzip the `.zip`.
2. Double-click the `.utm` that appears (or **File → Import** in UTM).
3. Boot the VM.

Logs in on its own, no password prompt.

## Credentials

| | |
|---|---|
| User | `omarchy` |
| Password | `omarchy` (also for root) |

**Change the password as soon as you log in:** open a terminal and run
`passwd`.

## Keyboard

macOS claims the Cmd key before UTM ever sees it (Cmd+Space opens
Spotlight), so the VM is set up with Alt and Super swapped:

| Mac key | In the VM |
|---|---|
| **Option (⌥)** | SUPER |
| Cmd (⌘) | ALT |

Main shortcuts: **⌥+Space** opens the Omarchy menu, **⌥+Return** a
terminal, **⌥+K** the full shortcut list.

If you'd rather keep the original behavior, remove `altwin:swap_lalt_lwin`
from `~/.config/hypr/input.lua` and enable UTM's input capture (requires
granting UTM Accessibility and Input Monitoring permissions in System
Settings → Privacy & Security).

## What to expect

Works: the full Hyprland desktop with the Omarchy bar, themes, menu,
terminal, browser, and all 439 `omarchy-*` commands.

Also includes Omarchy's own tools **compiled for aarch64**, which are not
published for ARM: `tensaku` (screenshot annotation), `omacalc`,
`omacut`, `omawrite`, `aether` (themes), `cliamp` (player), `ttfx`
(screensaver effects), `omarchy-nvim`, `mise`, `tzupdate`, `yaru-icon-theme`,
`ttf-ia-writer`, `hyprland-preview-share-picker`, `xdg-terminal-exec`,
`tobi-try`, `ufw-docker` and `yay`.

And two free-software applications already built for ARM: **OBS Studio
32.2.2** (without the browser plugin, whose CEF is x86-only) and **Pinta 3.1.2**
(on top of Microsoft's official arm64 .NET).

Limitations inherent to running Omarchy on ARM:

- **No GL acceleration inside the VM.** Windows are drawn in software
  (llvmpipe). Under virtio-gpu, GPU clients get mapped but not painted; blur
  and shadows are disabled to compensate. Smooth enough for normal use, not
  for video or 3D.
- **`herdr` is missing**: it wants Zig 0.15 semantics, and neither ARM nor
  x86_64 packages that version anymore (both are on 0.16).
- **The disk ships compressed** inside the `.qcow2`. It takes half the space
  and decompresses on the fly; if you'd rather trade space for read speed,
  `qemu-img convert -O qcow2 disco.qcow2 sin-comprimir.qcow2`.

## Clipboard and shared folder

**The clipboard works both ways**: copy on the Mac and paste in the VM, and
vice versa. Text only. Two conditions:

- **"Share clipboard" enabled** in UTM (*VM Settings → Sharing*).
- **The VM open as a window.** Started headless (`utmctl start`) there is no
  SPICE client connected, so the channel exists but carries nothing.

If it's not working, this tells you at which of the three hops it breaks
— SPICE client → `spice-vdagentd` → Hyprland session —:

```bash
systemctl is-active spice-vdagentd              # the daemon
systemctl --user status omarchy-arm-vdagent     # your session's agent
```

**Shared folder**: pick one in *VM Settings → Sharing* and inside the VM run
`omarchy-arm-share`. It detects whether UTM is in VirtFS mode or SPICE WebDAV
mode and mounts it at `/mnt/share` accordingly.
`omarchy-arm-share --status` shows how it landed, `--umount` releases it.

## The apps that aren't included

1Password, Obsidian, Typora, LocalSend and Google Chrome are **not in the
image**, but not because they don't work: all of them have an official ARM64
build. They're left out because they're proprietary, and bundling them into
an image that gets distributed would mean redistributing third-party
binaries.

The image ships an installer that downloads them from their official source:

```bash
omarchy-arm-extras --list     # see what it can install
omarchy-arm-extras            # interactive menu
omarchy-arm-extras obsidian   # a specific one
omarchy-arm-extras --all      # everything missing
```

The listing marks `[already installed]` for what the image already ships,
and `--all` skips those.

It's also in the app menu as **"Install missing apps (ARM)"**.

| Key | What it does |
|---|---|
| `1password` | Official arm64 tarball, with GPG signature verification |
| `1password-cli` | The `op` command, static arm64 binary |
| `obsidian` | Official arm64 tarball |
| `typora` | Official arm64 package via AUR |
| `localsend` | Official arm64 build |
| `chrome` | Ships Widevine for arm64: enables Spotify and Netflix web |
| `spotify-web` | Web launcher + remaps `⌥+Shift+M` |
| `pinta` | Already installed; the key is there to reinstall it |
| `obs` | Already installed; the key is there to reinstall it |

**About Spotify**: there's no native ARM client, but the web player does
work — it needs Widevine, which comes with Google Chrome arm64. Install
`chrome` and then `spotify-web`. In the terminal you already have
`spotify-player` installed.
- **`omarchy-update` works**, but once Omarchy introduces a new package of
  its own, it will skip it with a warning instead of installing it.

## Resolution

Fixed at 1920x1200. To change it, edit `~/.config/hypr/monitors.lua` and
**restart the VM** — changing the mode live leaves the screen blank under
virtio-gpu.

## Note

Unofficial image, unaffiliated with Basecamp or the Omarchy project.
Omarchy only supports x86_64; this is an equivalent rebuild on
Arch Linux ARM.
