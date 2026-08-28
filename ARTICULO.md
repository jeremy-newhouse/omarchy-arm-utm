# Omarchy on Apple Silicon Mac: when the guide stops working

How to rebuild the Omarchy desktop on Arch Linux ARM inside UTM, why the
official path is closed, and the ten obstacles you only discover by hitting
them.

---

## The starting point

Omarchy is DHH's desktop distribution: Arch Linux with Hyprland, polished
themes, and some 430 custom utilities. The question was simple:
**can you get that on a virtual machine on an Apple Silicon Mac?**

There's a reference guide, [discussion
#452](https://github.com/basecamp/omarchy/discussions/452) of the repo, that
describes exactly that. The problem is it's from 2025 and the project moves
fast.

### First things first: check that the guide still holds

Four checks were enough to rule it out. None require installing anything:

```bash
# 1. The endpoint the guide uses
curl -sI https://omarchy.org/install-bare | head -1
# → HTTP/2 404

# 2. The Omarchy mirror, for aarch64
curl -sI https://stable-mirror.omarchy.org/core/os/aarch64/core.db | head -1
# → HTTP/2 404          (the x86_64 one returns 200)

# 3. The installer guard... on the 3.x branch
curl -s https://raw.githubusercontent.com/basecamp/omarchy/master/install/preflight/guard.sh \
  | grep -A2 'x86 only'
# → if [[ $(uname -m) != "x86_64" ]]; then
# →   abort "x86_64 CPU"

# 4. The real state of ARM support, in the ISO's own repo
curl -s https://raw.githubusercontent.com/omacom-io/omarchy-iso/main/plans/aarch64-support.md \
  | head -20
# → "Plan: aarch64 ... Target: a parallel generic UEFI aarch64 ISO"
```

That fourth point is the most informative one: the Omarchy team **already
wrote the plan** to support aarch64, and in that document they list the
blockers they themselves have. Among others: *"`pkgs.omarchy.org/{stable,edge}/aarch64/`
must serve a real repo. Probed today, both return 404"*.

There's one detail that seals the matter. The Omarchy installer overwrites
the entire mirror list — in quattro, from `install/post-install/pacman.sh` —
with `stable-mirror.omarchy.org/$repo/os/$arch`. On ARM, the first `pacman
-Syu` afterward fails, because that mirror doesn't serve aarch64.

### Correction: on quattro that guard no longer exists

Months later I checked again, and point 3 **was no longer true**. Cloning
both branches:

| Branch | `install/preflight/guard.sh` | `uname -m` across the repo |
|---|---|---|
| `master` (3.8.x) | exists, line 25 | 1 occurrence |
| **`quattro` (4.x, the default one)** | **the `preflight/` directory doesn't exist** | **0 occurrences** |

Omarchy 4 **doesn't refuse to run on ARM64**. What's missing is the
repository: the tree is shell, Lua, and QML, architecture-agnostic, and the
`omarchy` package itself is declared `arch=('any')`. The blocker went from
"refuses" to "nowhere to install from," which is a much smaller problem — it
would be closed by publishing about 25 aarch64 packages — and it also
explains why several third-party projects have had to stand up their own
separate repository.

I'm leaving the mistake in view instead of rewriting history, because it's
representative: **I checked against the wrong branch**. `master` sounds like
the main branch; in this repo the default is `quattro`. The same trap that
had already cost me an emergency-mode boot, again, in another place.

### The decision

If Omarchy can't be installed, it can be **rebuilt**: set up Arch Linux ARM
with Hyprland and apply the actual content of the Omarchy repository —
config, themes, utilities — which is where 90% of the experience lives.

Before writing a line of code, it's worth measuring whether that produces
anything usable. You can find out without installing anything, by
cross-referencing Omarchy's package list against the Arch Linux ARM index:

```bash
# Arch Linux ARM package index for aarch64
curl -s http://mirror.archlinuxarm.org/aarch64/core/core.db   -o core.db
curl -s http://mirror.archlinuxarm.org/aarch64/extra/extra.db -o extra.db
mkdir db && cd db && tar -xzf ../core.db && tar -xzf ../extra.db
ls -1 | sed -E 's/-[^-]+-[^-]+$//' | sort -u > ../alarm.txt

# Omarchy package list
curl -s https://raw.githubusercontent.com/basecamp/omarchy/quattro/install/omarchy-base.packages \
  | grep -vE '^#|^$' > omarchy.txt

comm -12 <(sort omarchy.txt) ../alarm.txt | wc -l   # available
comm -23 <(sort omarchy.txt) ../alarm.txt           # the ones missing
```

Result: **121 of 148 packages exist on ARM** under the exact name — 123 if you
substitute `nvim` for `neovim` and `ttf-jetbrains-mono-nerd-basic` for
`ttf-jetbrains-mono-nerd`, which is what the `prepare` phase does. The ones
missing are proprietary apps (1Password, Spotify, Obsidian, Typora) and
Omarchy's own packages. And the important part: `hyprland`, `hyprlock`,
`hypridle`, `waybar`, `quickshell`, `uwsm`, `sddm`, `mesa`, and `chromium` are
all there, at current versions. Arch Linux ARM **keeps pace** with Arch:
`firefox 154.0-1` on both.

With those numbers, the project makes sense.

---

## The build architecture

Three structural decisions, each with its own reason.

**Headless build.** Booting an installer and clicking through it isn't
reproducible. The whole process happens in a QEMU VM driven by `expect` over
the serial console. If something fails, you fix the script and rerun it.

**HVF acceleration.** Since the guest is aarch64 and so is the host, you can
use macOS's native hypervisor instead of emulating. The difference is an
order of magnitude:

```bash
qemu-system-aarch64 -accel hvf -cpu host -M virt,highmem=on,gic-version=3 ...
```

**Alpine as the boot environment.** Arch Linux ARM doesn't publish an
installer ISO, only a rootfs tarball. You need a minimal Linux that can
partition the disk and deploy that tarball. Alpine `virt` weighs 88 MB, boots
in seconds, and drops straight to a serial console.

The skeleton looks like this:

```
Alpine live (QEMU + HVF, serial console)
  └─ stage 1: partition, deploy the ALARM rootfs, chroot
       └─ stage 2 (root): kernel, UEFI boot, packages, user
            └─ stage 3 (user): Omarchy, AUR, themes
```

---

## Step by step

### 1 · Dependencies

```bash
brew install qemu expect aria2
brew install --cask utm
```

### 2 · Base images, with verification

```bash
aria2c -x8 https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-virt-3.24.1-aarch64.iso
aria2c -x8 http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz

# The tarball is rebuilt every few weeks: always verify
curl -s http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.md5
md5 -q ArchLinuxARM-aarch64-latest.tar.gz
```

### 3 · Partitioning and rootfs deployment

Inside Alpine. First non-obvious detail: **you have to load the btrfs module
by hand**. Alpine's `virt` kernel ships it as a module but doesn't
autoload it, and `mkfs.btrfs` works fine (it's userspace) while `mount` fails
with a baffling *"Invalid argument"*.

```sh
modprobe btrfs vfat
grep -qw btrfs /proc/filesystems || exit 1   # actually check

parted -s /dev/vda mklabel gpt
parted -s /dev/vda mkpart OMBOOT fat32 1MiB 1025MiB
parted -s /dev/vda set 1 esp on
parted -s /dev/vda mkpart OMROOT btrfs 1025MiB 100%
mkfs.vfat -F32 -n OMBOOT /dev/vda1
mkfs.btrfs -f -L OMROOT  /dev/vda2

mount /dev/vda2 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt
mount -o rw,noatime,compress=zstd:3,subvol=@     /dev/vda2 /mnt
mkdir -p /mnt/home
mount -o rw,noatime,compress=zstd:3,subvol=@home /dev/vda2 /mnt/home
```

**Second detail: the ESP is mounted *after* extracting the rootfs.** The
ALARM tarball contains symlinks under `/boot`, and vfat doesn't support them.
If the ESP is mounted during extraction, `bsdtar` fails. The fix is to
extract first, discard that `/boot`, and let pacman repopulate it over the
now-mounted ESP:

```sh
bsdtar -xpf alarm-rootfs.tgz -C /mnt      # -p preserves permissions and xattrs
rm -rf /mnt/boot && mkdir /mnt/boot
mount /dev/vda1 /mnt/boot
```

### 4 · Base system and UEFI boot

Inside the chroot. Arch Linux ARM has **its own keyring**, distinct from
Arch's:

```bash
pacman-key --init
pacman-key --populate archlinuxarm     # not "archlinux"
pacman -Syu --noconfirm
pacman -S --noconfirm --needed base base-devel linux-aarch64 sudo git \
  networkmanager btrfs-progs dosfstools efibootmgr
```

The initramfs needs the virtio modules listed explicitly, because
mkinitcpio's `autodetect` runs inside a chroot where the running kernel is
still Alpine's:

```bash
sed -i 's/^MODULES=.*/MODULES=(virtio virtio_pci virtio_blk virtio_scsi virtio_net virtio_gpu btrfs)/' \
  /etc/mkinitcpio.conf
mkinitcpio -P
```

And here's the **third non-obvious detail**, the one that decides whether the
VM boots at all:

```bash
bootctl --esp-path=/boot --no-variables install
```

`--no-variables` avoids writing entries to UEFI NVRAM. Why? Because the build
VM's NVRAM **doesn't travel** with the UTM bundle: they're separate variable
files. Boot has to rely on the fallback path `\EFI\BOOT\BOOTAA64.EFI`, which
`bootctl` installs regardless. If you rely on NVRAM, the VM builds fine and
then won't boot in UTM.

### 5 · Omarchy: the surprise

This is where the project got genuinely complicated.

```bash
git clone --depth 1 https://github.com/basecamp/omarchy.git ~/.local/share/omarchy
mkdir -p ~/.config
cp -R ~/.local/share/omarchy/config/* ~/.config/
```

Two lines and done, in theory. In practice, Hyprland booted into
**emergency mode**:

```
⚠ Emergency mode tripped: A lua config error resulted in no binds being registered.
cannot open /usr/share/omarchy/default/hypr/bootstrap.lua: No such file or directory
```

Two chained discoveries, and both deserve their own section.

---

## The obstacles

### 1 · `git clone` doesn't fetch `master`

```bash
curl -s https://api.github.com/repos/basecamp/omarchy | jq -r .default_branch
# → quattro

curl -s https://raw.githubusercontent.com/basecamp/omarchy/master/version    # → 3.8.5
curl -s https://raw.githubusercontent.com/basecamp/omarchy/quattro/version   # → 4.0.0.alpha
```

The default branch **is not `master`**. A `git clone` without `--branch`
fetches `quattro`, which is Omarchy 4, a different product from the 3.8.5
that `master` documents:

| | `master` (3.8.5) | `quattro` (4.x) |
|---|---|---|
| Bar | waybar | **quickshell** (`omarchy-shell`) |
| Hyprland config | `.conf` files | **Lua** (`hyprland.lua`) |
| Distribution | scripts in `$HOME` | **pacman package** in `/usr/share/omarchy` |

Practical consequence: I had installed the `master` package list — with
waybar — on a system running `quattro` — which uses quickshell. The bar
simply didn't exist. And `quickshell 0.3.1` **is available** on Arch Linux
ARM; I just didn't know I needed it.

**Lesson:** when a project moves fast, check the default branch before
reading its documentation.

### 2 · Omarchy 4 is a pacman package

Version 4 ships as a package, not as scripts in `$HOME`. That package places
files at fixed system paths:

- `/usr/share/omarchy` — the full tree
- `/usr/bin/omarchy-*` — the binaries on PATH
- `/etc/profile.d/omarchy.sh` — the hook for shells
- `/usr/share/uwsm/env.d/10-omarchy` — the hook for the graphical session

Worth being precise here, because I got this wrong myself at first: **the
package is not x86_64-only**. Its PKGBUILD declares `arch=('any')` — it's
shell, Lua, and QML — and installs the commands into `/usr/bin`, symlinked
from `/usr/share/omarchy/bin`. What's x86_64-only is the **repository** it's
published from. On ARM there's nowhere to install it from, and that's where
the problem starts: cloning the repo into `$HOME` leaves `OMARCHY_PATH`
undefined, `.bashrc` errors out, Hyprland can't find its `bootstrap.lua`, and
none of the autostart works.

The fix is to replicate by hand what the package would do:

```bash
sudo ln -sfn "$OMARCHY_PATH" /usr/share/omarchy
for f in "$OMARCHY_PATH"/bin/*; do
  sudo ln -sfn "$f" "/usr/bin/$(basename "$f")"           # 439 binaries
done
sudo install -Dm644 "$OMARCHY_PATH/etc/profile.d/omarchy.sh" /etc/profile.d/omarchy.sh
sudo install -Dm644 "$OMARCHY_PATH/default/uwsm/env.d/10-omarchy" \
  /usr/share/uwsm/env.d/10-omarchy
```

This ended up in `/usr/bin`, not `/usr/local/bin`. I started with
`/usr/local/bin` to avoid stepping on pacman's territory, which seemed like
the clean choice, and it broke things: the Omarchy tree has
`/usr/bin/omarchy-*` hardcoded in thirteen places, five of them `.service`
files. `/usr/local/bin` is still used, but only for the ARM-specific
wrappers that need to win on PATH.

Interesting aside: Omarchy has a mechanism built exactly for this,
`omarchy-dev-link`, which writes `/etc/omarchy.conf` to point the system at a
local checkout. It exists for developing Omarchy, but it works just as well
for this case.

### 3 · The Super key, hijacked by macOS

Omarchy uses SUPER for everything. On a Mac, SUPER is Cmd, and **macOS
intercepts Cmd before UTM ever sees it**: Cmd+Space opens Spotlight, not the
Omarchy menu.

You can fight with UTM's input-capture permissions, or fix it inside the
guest with one line:

```lua
-- ~/.config/hypr/input.lua
hl.config({
  input = {
    kb_layout  = "es",
    kb_options = "compose:caps,shift:both_capslock_cancel,altwin:swap_lalt_lwin",
  },
})
```

`altwin:swap_lalt_lwin` swaps Alt and Super. Result: the **Option (⌥)** key
acts as SUPER, and macOS doesn't intercept Option+Space.

Along the way, another detail: Hyprland reads the keyboard layout from
`XKBLAYOUT` in `/etc/vconsole.conf`, not from `KEYMAP`. Setting only
`KEYMAP=es` leaves Hyprland on `us`. Both need to be set.

### 4 · Windows that open invisible

The most confusing symptom: the desktop was visible, the keyboard worked,
menus appeared… but opening a terminal produced nothing on screen. `hyprctl`
confirmed it:

```
Window aaaad1ec7630 -> Alacritty:
    mapped: 1
    size: 1896,1150
    workspace: 1
```

Window mapped, sized, on the visible workspace. And on screen, only the
background.

The test that isolated it was comparing two terminals:

```bash
foot       # draws with shared-memory buffers (wl_shm)  → VISIBLE
alacritty  # draws with EGL/GPU (dma-buf)                → NOT VISIBLE
```

In other words: under `virtio-gpu` with virgl, clients that use the GPU
produce buffers that Hyprland can't composite. The compositor renders its own
stuff — bar, background, menus — but application windows stay empty.

What **doesn't** fix it, checked one by one:

- `AQ_NO_MODIFIERS=1` — already active
- `render:explicit_sync` — removed in Hyprland 0.56
- `render:cm_enabled = false` — no effect

What does:

```bash
# /etc/environment.d/90-vm-graphics.conf
LIBGL_ALWAYS_SOFTWARE=1
```

Mesa switches to llvmpipe, clients deliver `wl_shm` buffers, and everything
renders. The cost is real: GL acceleration is lost **inside** the VM. As a
tradeoff, it's worth disabling blur and shadows, which get expensive under
CPU rendering.

One nuance that cost an hour: testing over SSH made it look like it wasn't
working. `/etc/environment.d/` is read by the **systemd session manager**,
not a login shell. An app launched from SSH doesn't inherit the variable; one
launched from the graphical session does. The bug was in the test method, not
in the fix.

### 5 · Changing resolution on the fly breaks rendering

Setting 1920x1200 with `hyprctl reload` left the screen **blank**. The layers
were still there (`hyprctl layers` listed them, with alpha 1), but they
weren't being painted. Restarting the shell wasn't enough; the whole VM had
to be restarted.

Applied **from boot**, the same resolution works perfectly.

```lua
-- ~/.config/hypr/monitors.lua
hl.env("GDK_SCALE", "1")
hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })
```

If you touch that file, restart the VM instead of reloading the config.
(`scale = 1` matters too: Omarchy assumes retina screens and with the
default value everything comes out gigantic in a VM.)

### 6 · `omarchy-update` was blowing up

On update, the output ended in an error. The pacman log told the story:

```
Running 'pacman -Rns --noconfirm dust'      → removed
Running 'pacman -S --noconfirm tensaku'     → doesn't exist on ARM → error
```

An Omarchy **migration** had removed `dust` to replace it with `tensaku`, a
custom package that doesn't exist on ARM. And it left the system with
neither.

The root cause was in the build:

```bash
ls ~/.local/state/omarchy/migrations | wc -l   # 8
ls /usr/share/omarchy/migrations/*.sh | wc -l  # 83
```

A normal Omarchy installer **seals every migration once it finishes**,
because a freshly installed system is already born in the final state:
migrations exist to bring old installs up to date. By cloning the repo
without sealing them, `omarchy-update` tried to replay 75 historical
migrations.

Two fixes. First, seal them:

```bash
mkdir -p ~/.local/state/omarchy/migrations
for f in /usr/share/omarchy/migrations/*.sh; do
  : > ~/.local/state/omarchy/migrations/"$(basename "$f")"
done
```

The second is the one that matters long-term. `omarchy-pkg-add` aborts if a
package doesn't exist, and that takes down the whole update. A wrapper in
`/usr/local/bin` makes it tolerant:

```bash
#!/bin/bash
REAL=/usr/share/omarchy/bin/omarchy-pkg-add
avail=(); skip=()
for p in "$@"; do
  if pacman -Q "$p" &>/dev/null || pacman -Si "$p" &>/dev/null; then
    avail+=("$p")
  else
    skip+=("$p")
  fi
done
((${#skip[@]})) && printf 'Skipped, not available on ARM: %s\n' "${skip[*]}" >&2
((${#avail[@]})) || exit 0
exec "$REAL" "${avail[@]}"
```

Without this, every new package Omarchy introduces would break updates
again.

### 7 · The gray desktop: two failures no log reported

The last check before packaging was to look at a screenshot of the
already-sanitized desktop. It booted, the bar was there, the clock showed
the time. But the background was flat gray and notifications were plain gray
boxes with no styling. Not one error in `journalctl`, not one warning on
screen. Two independent causes, and both share the same shape: **the system
kept working, just badly**.

**`grep -r` doesn't see where a symlink points.** When renaming the user from
`gabriel` to `omarchy`, I checked the result like this:

```bash
grep -rl '\bgabriel\b' /etc /home/omarchy/.config     # → 0 matches
```

Zero. Clean. Except a symlink's target isn't *content* of a file: `grep`
doesn't read it. And Omarchy stores the active theme and background
precisely as symlinks:

```
~/.local/state/omarchy/current/background -> …/theme/backgrounds/1-quattro.webp
```

The correct check is a different tool:

```bash
find /home/$NEW /etc /usr/local /opt -xdev -type l -lname "*/home/$OLD/*"
```

**439 dangling links**, including the **431 `omarchy-*` commands** in
`/usr/local/bin`, which pointed at the home directory that no longer existed.
The desktop booted because quickshell reads from `/usr/share/omarchy`, but
any menu command would have failed. Rewriting them is trivial once you see
them:

```bash
for l in "${BADLINKS[@]}"; do
  tgt=$(readlink "$l")
  ln -sfn "${tgt//\/home\/$OLD\//\/home\/$NEW\/}" "$l"
done
```

And verification now checks three things it didn't check before: links to
the old home, broken links, and whether the active background resolves.

**I installed four packages that Omarchy 4 retires.** The second failure was
entirely mine. My list of "infrastructure" packages came from reading
Omarchy 3, and it dragged along `mako`, `swayosd`, `walker`, and `elephant`.
None of them are in `quattro`'s `omarchy-base.packages`. The repo's own docs
say so outright, in `docs/notifications.md`:

> The shell is the notification daemon […] There is no dunst or mako.

And `bin/omarchy-upgrade-to-quattro` uninstalls them explicitly, along with
their user units. `mako` isn't inert: it activates over D-Bus on the first
`notify-send` and **claims `org.freedesktop.Notifications` before the shell
does**. The result is that quickshell loses the bus name and notifications
come out with mako's default styling. That's what the gray boxes were.

The launcher didn't need `walker` either: in quattro the menu is a
quickshell panel (`omarchy-shell shell toggle omarchy.menu`), so my
`fuzzel`-based replacement for `walker` was dead code from day one.

The lesson isn't "a stray package slipped in." It's that **a distribution's
package list is a statement about its architecture, not an inventory**. I
filled it out from memory of the previous version, and in doing so
reintroduced a component the new version had deliberately replaced.
Cross-checking against `omarchy-base.packages` — which is what the `prepare`
phase does — and not adding anything from intuition would have saved two
hours of diagnosis.

## The methodology error: "not available" isn't a category

Cross-referencing Omarchy's package list against the Arch Linux ARM index
turned up 25 absences. I filed them all into one bucket — "not available" —
and moved on. That was a mistake, and it took a while to discover.

That bucket mixed two things that aren't comparable:

- **Impossible**: 1Password, Spotify, Obsidian, Typora. Proprietary binaries
  built only for x86_64. Nothing to be done.
- **Nobody's built it yet**: almost everything else.

And I put `pinta` in the first bucket, which is the mistake inside the
mistake: Pinta is free software and Microsoft publishes .NET for linux-arm64.
Today it's compiled during the build and ships inside the image.
Misclassifying a single line cost weeks without an image editor.

Working reactively — compiling only what visibly broke something — I ended
up resolving `walker` and `elephant` believing there was no launcher without
them (false: the menu is a quickshell panel, see finding 7),
`xdg-terminal-exec` because it's `$TERMINAL`, and `ttfx` only once the
screensaver threw an on-screen error. Everything else stayed in the bucket.

The audit I should have run on day one is this, and it resolves with two
calls to the GitHub API and one to the AUR API:

```bash
# Does it exist on AUR?
curl -s "https://aur.archlinux.org/rpc/v5/info?arg[]=tensaku&arg[]=aether&arg[]=cliamp" \
  | jq -r '.results[] | "\(.Name) \(.Version) \(.URL)"'

# What language is it written in? (decides whether it's portable)
curl -s https://api.github.com/repos/omacom-io/omacalc | jq -r '.language'

# What does its PKGBUILD say?
curl -s https://raw.githubusercontent.com/omacom-io/omarchy-pkgs/master/pkgbuilds/omacalc/PKGBUILD \
  | grep -E '^(arch|makedepends)='
```

The result dismantles the bucket:

| Package | Origin | Language | Why it was missing |
|---|---|---|---|
| `omacalc`, `omacut`, `omawrite` | omacom-io | Qt / C++ | **its PKGBUILD already declares `aarch64`** |
| `aether`, `cliamp` | AUR | Go | portable |
| `herdr`, `tensaku`, `hyprland-preview-share-picker` | AUR / omacom | Rust | `arch=(x86_64)` by default |
| `omarchy-nvim`, `tobi-try` | omarchy-pkgs | — | `arch=any`, doesn't even compile |
| `yaru-icon-theme`, `ttf-ia-writer` | AUR | — | icons and fonts |
| `tzupdate`, `ufw-docker`, `mise-bin`, `localsend` | AUR | Python, shell, binary | portable |

**Of the 25 absences, 16 were buildable**, and three of them didn't even
require touching anything: just someone running `makepkg` on an ARM machine.

### Building them

The key observation is that many PKGBUILDs declare `arch=(x86_64)` because
the maintainer only builds for their own machine, not because the code is
incompatible. If it's portable Rust, Go, or C++, adding the architecture is
enough:

```bash
build_omarchy_tool() {                 # <aur|omapkgs> <package>
  local src="$1" pkg="$2"
  local dir="/tmp/omabuild/$pkg"
  pacman -Q "$pkg" >/dev/null 2>&1 && return 0

  case "$src" in
    aur) git clone --depth 1 -q "https://aur.archlinux.org/$pkg.git" "$dir" ;;
    omapkgs)
      git clone --depth 1 --filter=blob:none --sparse -q \
        https://github.com/omacom-io/omarchy-pkgs.git "$dir/repo"
      ( cd "$dir/repo" && git sparse-checkout set "pkgbuilds/$pkg" )
      cp -a "$dir/repo/pkgbuilds/$pkg/." "$dir/" && rm -rf "$dir/repo" ;;
  esac

  # The whole point: declare aarch64 when the code is portable
  grep -qE "^arch=.*(aarch64|'any')" "$dir/PKGBUILD" || \
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"

  ( cd "$dir" && makepkg -si --noconfirm --needed )
}
```

They build in order of increasing cost — data, Go, Qt, Rust — and none is
fatal: if one fails, the rest continue.

```bash
for spec in \
  aur:yaru-icon-theme aur:ttf-ia-writer aur:tzupdate aur:ufw-docker \
  omapkgs:omarchy-nvim omapkgs:tobi-try aur:mise-bin \
  aur:aether aur:cliamp \
  omapkgs:omacalc omapkgs:omacut omapkgs:omawrite \
  aur:herdr omapkgs:tensaku omapkgs:hyprland-preview-share-picker; do
  build_omarchy_tool "${spec%%:*}" "${spec#*:}"
done
```

And `ttfx`, which isn't on AUR, straight from its own repo:

```bash
git clone https://github.com/omacom-io/ttfx.git && cd ttfx
cargo build --release && sudo install -Dm755 target/release/ttfx /usr/local/bin/ttfx
```

Building all of it takes a while — the three Rust projects are the slowest
part — but it's machine time, not human time.

> **A bash trap along the way.** The function above started out as:
>
> ```bash
> local src="$1" pkg="$2" dir="/tmp/omabuild/$pkg"    # ← fails with set -u
> ```
>
> Bash **expands every value in a `local` before assigning any of them**, so
> `$pkg` doesn't exist yet when `$dir` is built, and with `set -u` the script
> aborts on the first call. It has to be split into two statements.

### The result

Of the 25 absences, **20 ended up installed**. Only one held out, for a
specific reason: `herdr` invokes `zig fetch` with Zig 0.15 semantics while
the repos are on 0.16 — it fails with *"no build.zig file found"*. Worth
noting **this has nothing to do with ARM**: `zig 0.16.0-1` is the version on
both Arch Linux ARM and x86_64, so anyone would hit the same snag. Building
Zig 0.15 from source is a matter of hours, and it's a development tool, not
part of the desktop.

The rest of the absences are the genuinely impossible ones: proprietary
binaries built only for x86_64.

Four of the five stumbles along the way were defects in my own script, not
real incompatibilities, and all four would break anyone's build:

| Symptom | Cause |
|---|---|
| Dies on the first call with `pkg: unbound variable` | A single `local` expands **all** values before assigning any of them |
| `Can not use 'any' architecture with other architectures` | The PKGBUILD carries `arch=(any)` **unquoted**, and the guard only checked the quoted form |
| The AUR clone comes out empty | AUR URLs use the **PackageBase**, which isn't always the package name: `yaru-icon-theme` lives in the `yaru` repo |
| `failed to prepare transaction` on install | The PKGBUILD produces **several subpackages**, and only one has a missing dependency. You have to build without installing, then install the specific subpackage |

And one final irony: when installing the Yaru icons, `pacman` complained
about two conflicting files… created by Omarchy's own `theme-system.sh`,
precisely because the theme wasn't installed yet. It's resolved with
`--overwrite '/usr/share/icons/*'` and reapplying the symlinks afterward.

## What about hitting "Update System"?

This is the question that matters most long-term, and the initial answer was
"no." Three things prevented it, and none is obvious until you read the
code.

### The Omarchy tree never updated

`omarchy-update` calls `omarchy-update-dev`, whose first line is:

```bash
[[ $OMARCHY_PATH != "/usr/share/omarchy" ]] || exit 0
```

It exits immediately if `OMARCHY_PATH` is the canonical path, because it
assumes the pacman package owns that location. On an ARM install, that's a
**git checkout**, and nobody updates it. The system would receive new
packages while Omarchy's scripts, themes, and config stay frozen forever.

You can see it with two commands:

```bash
git -C /usr/share/omarchy log -1 --format=%h    # ed7bae4  (August 20)
git -C /usr/share/omarchy fetch --dry-run       # ed7bae4..2c247e3  quattro
```

The fix fits Omarchy's own design: a hook in
`~/.config/omarchy/hooks/post-update.d/` that does the `git pull` and links
the new binaries.

```bash
git -C "$TREE" pull --ff-only
for f in "$TREE"/bin/*; do
  t="/usr/bin/$(basename "$f")"
  [ -e "$t" ] && [ ! -L "$t" ] && continue   # respects custom wrappers
  [ -L "$t" ] && continue
  sudo ln -sfn "$f" "$t"
done
sudo find /usr/bin -xtype l -delete
```

### No safety net

`omarchy-snapshot create` returns 127 if snapper isn't installed, and
`omarchy-update` treats that as "continue without a snapshot." In other
words: every update on a rolling release, with no way back.

`snapper` is on Arch Linux ARM and Omarchy ships its own configurator:

```bash
sudo pacman -S snapper
sudo bash -euo pipefail /usr/share/omarchy/install/config/snapper.sh
```

With systemd-boot there's no snapshot selection in the boot menu — that
comes from `limine-snapper-sync` — but the snapshots exist and are restored
with `snapper rollback`.

### An infinite loop hiding in a symlink

I introduced this one myself, and it's the most instructive. The
`omarchy-pkg-add` wrapper was created like this:

```bash
sudo tee /usr/local/bin/omarchy-pkg-add <<'WRAP'
REAL=/usr/share/omarchy/bin/omarchy-pkg-add
...
exec "$REAL" "${avail[@]}"
WRAP
```

Looks correct. The problem is that `/usr/local/bin/omarchy-pkg-add` **was a
symlink into the tree**, and `tee` follows symlinks: it overwrote Omarchy's
original script with the wrapper, whose `REAL` now pointed at itself. Every
call recursed until it hung the whole update.

It didn't surface earlier because it only fires when a migration installs a
package, and all of them were sealed. It showed up the moment the first new
migration landed. It's detectable with `git status` in the tree:

```
 M bin/omarchy-pkg-add        ← content modified, shouldn't be
```

Two lessons: **`tee` follows symlinks and `install` doesn't**, and a git
checkout is a good detector for accidental writes to places that should be
immutable.

### And a third one that the same `git status` uncovered

```
 mode change 100644 => 100755 bin/omarchy-remove-service-dropbox
```

A `chmod +x` over the tree's binaries left the checkout dirty, and `git pull
--ff-only` refuses to update with pending changes. It's fixed with `git
config core.fileMode false` **before** the chmod.

### Result

With that, a full cycle runs through prune, snapshot, tree `git pull`,
keyring, `pacman -Syu`, migrations, hook, AUR, and mise:

```
Omarchy tree:       2c247e3  (0 dirty files)
migrations:         84 sealed, 0 pending
snapshots:          5
failed units:       0
```

Including a new migration that arrived with the pull and applied itself.

---

## The UTM bundle, written by hand

UTM doesn't let you create machines from the command line: `utmctl` only
manages the lifecycle. But the `.utm` format is documented in the source
code, and a hand-written `config.plist` works perfectly.

Three things worth knowing:

**The ten top-level keys are mandatory.** They're decoded with `decode()`,
not `decodeIfPresent()`: omitting even an empty `<array/>` makes UTM reject
the bundle. They are `Information`, `System`, `QEMU`, `Input`, `Sharing`,
`Display`, `Drive`, `Network`, `Serial`, and `Sound`.

**The aarch64 UEFI firmware VARS half is `edk2-arm-vars.fd`**, not
`edk2-aarch64-vars.fd`, which doesn't exist. The CODE half is supplied by UTM
at runtime.

**UTM doesn't watch the machines folder.** `listRefresh()` runs exactly once,
at app startup. A bundle copied there while UTM is open stays invisible
until you close and reopen the app.

The keys that matter for performance:

```xml
<key>Architecture</key> <string>aarch64</string>
<key>Target</key>       <string>virt</string>
<key>Hypervisor</key>   <true/>                      <!-- HVF, no emulation -->
<key>Hardware</key>     <string>virtio-gpu-gl-pci</string>
<key>UEFIBoot</key>     <true/>
```

---

## Preparing the image for distribution

An image someone else is going to use carries more inside than it looks:
SSH keys, `machine-id`, the SSH server's host keys, git identity, shell
history, saved wifi networks, and logs.

```bash
# machine identity (regenerates itself on boot)
: > /etc/machine-id
rm -f /etc/ssh/ssh_host_*

# personal identity
rm -rf /home/$U/.ssh /home/$U/.gnupg /home/$U/.gitconfig /home/$U/.bash_history
rm -f  /etc/NetworkManager/system-connections/*

# logs and caches
rm -rf /var/log/journal/* /var/cache/pacman/pkg/*

# the backups usermod leaves behind carry the old user and password hash
rm -f /etc/passwd- /etc/shadow- /etc/group-

# frees unused space so the qcow2 compresses better
fstrim -av
```

A detail that's easy to miss: if `/usr/share/omarchy` is a symlink into a
user's `$HOME`, renaming that user breaks the system. Convert it into a real
directory before renaming anything.

Then, compact:

```bash
# -c compresses clusters within the qcow2 itself: the image takes up half
# the space even after unzipping, at the cost of decompressing on read
qemu-img convert -c -O qcow2 dist.qcow2 slim.qcow2   # 11.6 GB → 6.6 GB
qemu-img check slim.qcow2
zip -r -1 omarchy-arm-utm.zip "Omarchy ARM.utm"
```

And a precaution you only learn by breaking it: **after sanitizing, the
image must not boot again**. The first boot regenerates `/etc/machine-id`,
the randomness seed, and the logs; if you boot it to check something, you
have to redo the sanitization. Verifying without dirtying it is done with an
overlay layer:

```bash
qemu-img create -f qcow2 -b slim.qcow2 -F qcow2 prueba.qcow2
```

---

## What you get, and what you don't

**Works:** native Arch Linux ARM aarch64 with HVF, `linux-aarch64` 7.2
kernel, btrfs with subvolumes and zstd compression, Hyprland 0.56.1 with the
full Omarchy 4 stack — quickshell as bar, menu, OSD, and notification daemon,
hyprlock, hypridle, uwsm, SDDM with autologin —, the themes, the 439
`omarchy-*` commands, and `omarchy-update`.

**Doesn't work:** GL acceleration inside the VM (rendered in software), and
`herdr`, which requires Zig 0.15 semantics while the repos are already on
0.16 — on ARM and x86_64 alike. Proprietary apps (1Password, Obsidian,
Typora, LocalSend, Chrome) don't ship inside for licensing reasons, but all
of them have an official ARM64 build and `omarchy-arm-extras` fetches them
from source.

**And it's worth saying plainly:** this isn't Omarchy. It's a reconstruction
of the Omarchy desktop on a different base. Omarchy supports x86_64; once
they ship the aarch64 ISO they've already planned, this work stops being
necessary.

---

## Auditing the script: 37 defects where I thought there were none

The question was simple: "do we have a single script capable of installing
EVERYTHING from scratch while dodging every known issue?" My impression was
yes. I could have just answered that.

Instead of trusting my impression, I cross-checked the script against its
own sources of truth — the 16 scripts in `fixes/`, the findings in this
article, a simulated run on a clean Mac — and ran every finding past an
independent refuter whose job was to tear it down. **37** survived, nine of
them blocking. All of them had existed for days. None had surfaced on its
own.

They group into three shapes, and all three share something in common: **the
system kept working**.

### 1 · Dead code from permissions

`stage3` runs as a normal user. It checked like this whether it needed to
install the optional-apps installer:

```bash
if [ -f /root/prov/omarchy-arm-extras ]; then
```

`/root` is `0750`. An unprivileged user can't even `stat` inside it, so the
condition **returns false without erroring**. The whole block had gone days
without ever running once, silently. Same with the update hook.

### 2 · Destructive ordering within the same script

The sanitizer, in step 7:

```bash
rm -rf /root/prov /root/.bash_history /root/.cache
```

And in steps 8a and 8b, twenty-five lines further down, it reads the hook
and the installer from `/root/prov`. It was deleting its own input before
using it. The log quietly said "wasn't on the recovery ISO," and I'd blamed
the filename inside the ISO.

### 3 · Phases structurally incapable of failing

This is the systemic one, and the one that interests me most. The script
uses `set -uo pipefail` **without `-e`**, and each phase is a function that
returns the status of its last command, which is almost always an `ok
"..."`. Result: four of the eight phases couldn't fail.

| Phase | How it swallowed the error |
|---|---|
| `build` | `su - user -c stage3.sh \|\| warn` — a `stage3` that blew up entirely still reported a correct disk |
| `utm` | `make-utm.sh ... \| tail -4` followed by `ok` — the pipe discards the exit code |
| `verify` | collected `pgrep -c Hyprland` and never compared it against anything |
| `fetch` | announced "MD5 verified" even if the checksum's `curl` had failed |

The common shape is easy to spot: **a success message that depends on
nothing**. It's worth hunting for it deliberately in any long script: `grep
-n "|| warn\| | tail" build.sh` catches most of them.

### And one in the fix itself

While adding interactive mode, I wrote a `confirm` using `${ans,,}` to
lowercase the answer. `bash -n` gave it a pass. Testing it under a simulated
terminal with `expect`:

```
build-omarchy-arm.sh: line 91: ${ans,,}: bad substitution
```

`${var,,}` is bash 4. **macOS ships bash 3.2**, and there an expansion error
aborts the whole function: `confirm` didn't return "no," it returned
garbage, and the script carried on as if you'd said yes. A bug from the same
family as the ones I was fixing, committed while fixing them.

The operational lesson: `bash -n` validates syntax, not semantics or
version. Interactive code has to be run against a real pty.

### And the only test that counts: running it

With all 37 fixes in place, everything verified by reading and the payloads
synced byte for byte, there was still the usual question: does it work? A
full build from scratch, eight phases, on an M3 Max.

It found **three more failures that no amount of reading had caught**:

| Failure | How it showed up |
|---|---|
| `VM_FULLNAME=Omarchy ARM` unquoted in `config.env` | on `source`, `ARM` ran as a command → chroot dead with `rc=127` |
| `verify`'s heredoc left unquoted | the **host's** bash expanded the `$(...)`, so the checks ran on the Mac: `systemctl: command not found` |
| `spice-vdagentd` is a `static` unit | `systemctl enable` on it does nothing; you have to enable the `.socket` |

I introduced the first two while fixing the other thirty-seven. The third
had been there from the start.

And the result, with everything now fixed:

```
16/17 tools compiled (only herdr fails, due to the Zig version)
extras=yes  menu=yes  hook=yes          ← the three blockers, resolved
verify inside the guest:
  ### H=1 Q=1 BINS=439 BROKEN=1 UNITS=7 VER=4 CLIP=5/5
  VERDICT_OK
final image: 3.6 GB · 76 min deps to package
```

That verdict is from the certification run, with the builder already fixed.
It's worth looking at twice, because for months it meant nothing: the host
checked it with `grep -qa VERDICT_OK` on the log, and the log contains the
**echo** of the command itself, which has `then echo VERDICT_OK` inside
it. The phase could not fail. The log from the image I actually shipped
proves it: line 6 is the echo, line 8 says `VERDICT_KO`, and the builder
declared success anyway. Now the token travels split —
`VER"DICT_OK"` — something the echo can't reproduce.

That `extras=yes menu=yes hook=yes` is the proof that matters: those are the
three that had gone days without ever installing, silently, and that no
prior run had reported because the script declared itself correct
regardless.

---

## Reproducing it

The whole process lives in a single script with resumable phases:

```bash
./build-omarchy-arm.sh              # asks the minimum, then builds
./build-omarchy-arm.sh --yes        # unattended, with defaults
./build-omarchy-arm.sh --from build # resume from a phase
./build-omarchy-arm.sh --list       # list the phases
```

Phases: `deps`, `fetch`, `prepare`, `build`, `utm`, `verify`, `sanitize`,
`package`.

With a terminal it asks six things, all pre-filled from what it detects on
the Mac — timezone from `/etc/localtime`, keyboard from macOS preferences,
cores and RAM from `sysctl` — so they're answered with Enter. Three of them
change the outcome: whether to compile the extra tools (~40 min), whether to
include OBS Studio and Pinta (~45 min, the most expensive part of all), and
whether to prepare the image for distribution. Choosing "VM for yourself"
trims the phases down to `deps…verify` and keeps your user. Without a
terminal, or with `--yes`, it asks nothing and builds the full image, ready
to distribute.

Asking only that much is deliberate. The other fifteen parameters — Alpine
version, rootfs URL, Omarchy branch, locales — are implementation details,
not decisions: a question nobody wants to answer is noise.

The `prepare` phase deserves a comment. Instead of carrying a fixed package
list, it computes one on every run by cross-referencing Omarchy's live
branch against the Arch Linux ARM index. That way the build doesn't break
when Omarchy changes its packages — which it will — and it reports along the
way what got left out.

---

## What this exercise teaches

Almost all the time went into things you can't anticipate by reading
documentation: a default branch that isn't the one the project documents, a
distribution-model change mid-version, a graphics-compositing problem that
only isolates by comparing two different terminals, and a state machine —
the migrations — that an installer initializes and a git clone doesn't.

The pattern that paid off the most was **building the discriminating test**:
when windows weren't showing up, comparing `foot` against `alacritty`
pinpointed the cause in a minute, after a good while flailing at environment
variables. And the mistake that cost the most time was trusting a test
method — launching apps over SSH — that didn't reproduce the real
conditions.
