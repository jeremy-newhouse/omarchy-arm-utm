# How to Run It

> Also published as a page:
> https://claude.ai/code/artifact/630abf6c-6d3e-4e92-81b2-bfc0a3073c70

Two paths. The first takes ten minutes; the second, one to two hours.

| | |
|---|---|
| **I just want the VM** | download [`omarchy-arm-utm-v2.zip`](https://archive.org/details/omarchy-arm-utm) (3.6 GB) and double-click → [jump to the end](#if-you-just-want-the-vm) |
| **I want to build it myself** | `./build-omarchy-arm.sh` → keep reading |

---

## 1 · What You Need

| Requirement | Why | How to Check |
|---|---|---|
| **Apple Silicon Mac** | the VM is native aarch64 with HVF; on Intel you'd have to emulate and it would take a day | `uname -m` → `arm64` |
| **macOS with Homebrew** | the script installs `qemu`, `expect`, and `aria2` if missing | `brew --version` |
| **UTM 4.7 or later** | this is where the VM gets registered | `brew install --cask utm` |
| **Command Line Tools** | the script uses `git` and `python3`, which come from there on macOS | `xcode-select -p` |
| **~40 GB free** | the build disk reaches ~13 GB and the packaging phase needs about as much again | `df -h ~` |
| **Decent connection** | downloads ~900 MB, then ~1,500 packages from the Arch Linux ARM repos | |

If something's missing, install it like this:

```bash
xcode-select --install                    # git and python3
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install --cask utm
```

**No `sudo` needed.** The script doesn't touch anything on the host system:
everything it needs it writes inside its own working directory, and the three
Homebrew dependencies install under your user.

## 2 · What Context the Script Needs

**None — it's a single file.** `build-omarchy-arm.sh` has the fifteen files it
needs embedded — the three install stages, the sanitizer, the repair harness,
the optional-app installer, the post-update hook, the clipboard agent and its
bridge, the shared-folder mounter, the VM config, the two `expect` harnesses,
the QEMU launcher, the `.utm` bundle generator, and the README that ships
inside the zip — and writes them to disk on startup. You can copy just that
one file to another Mac and it'll work the same.

The one thing you can hand it ahead of time, to save ~900 MB of download, are
the base images:

```bash
mkdir -p ~/omarchy-arm-build/dl
cp alpine-virt-*-aarch64.iso  ~/omarchy-arm-build/dl/alpine-virt-aarch64.iso
cp ArchLinuxARM-aarch64-*.tar.gz ~/omarchy-arm-build/dl/alarm-rootfs.tgz
```

The working directory is `~/omarchy-arm-build` unless you set another one:

```bash
W=/Volumes/Externo/omarchy ./build-omarchy-arm.sh
```

## 3 · Running It

```bash
./build-omarchy-arm.sh
```

And that's it. With a terminal, it'll first ask six questions **pre-filled
with what it detects from your Mac**, so you can just hit Enter:

```
━━━ configuration ━━━
  Timezone [Europe/Madrid]:                ← from /etc/localtime
  Keyboard (console) [es]:                 ← from macOS preferences
  Keyboard (Hyprland/Wayland) [es]:
  Cores for the VM [6]:                    ← half your performance cores
  Memory for the VM (MiB) [12288]:         ← based on your RAM
  Disk size [80G]:
```

Then the three that **do change the outcome**:

- **Compile the 17 Omarchy tools that don't exist for ARM?**
  ~40 minutes. If you say no, the desktop still works, but you'll be missing
  `ttfx` (the screensaver), `tensaku` (annotate screenshots), `omacalc`,
  `omacut`, `omawrite`, `aether`, `cliamp`, and `omarchy-nvim`. `aether` and
  `cliamp` can be added later with `yay -S`; the rest aren't in the AUR for
  aarch64 and you'd have to compile them by hand again, so saying yes here is
  cheap.

- **Include OBS Studio and Pinta?**
  They're free software, so they can ship inside the image, and the published
  one does. They cost ~45 minutes: OBS is compiled from source (without the
  browser plugin, whose CEF is x86-only) and Pinta needs Microsoft's official
  arm64 .NET. If you say no, add them later from inside with
  `omarchy-arm-extras pinta obs`.

- **Prepare the image for distribution?**
  - **No** (the question's default: just hit Enter): the VM keeps your user
    and your configuration. It skips `sanitize` and `package`, saving ~15
    minutes. Even so, `sshd` stays disabled, so you don't end up with a VM
    listening with a trivial password.
  - **Yes**: renames the user to `omarchy`, wipes SSH keys, git identity, and
    history, and generates a ~3.6 GB `.zip` with its `sha256`.

To skip all questions:

```bash
./build-omarchy-arm.sh --yes        # defaults, no prompts
```

Without a terminal (cron, CI, `nohup`), it doesn't ask either: it detects
there's no tty.

## 4 · What Happens and How Long It Takes

Measured on a real build on an M3 Max, with the tools compiled and without
OBS or Pinta:

| Phase | What It Does | Time |
|---|---|---|
| `deps` | checks the Mac and installs qemu/expect/aria2 if missing | seconds |
| `fetch` | downloads Alpine and the ALARM rootfs, verifying sha256 and MD5 | ~2 min |
| `prepare` | computes the package list by cross-referencing Omarchy's live branch against the ARM index | ~10 s |
| `build` | boots Alpine headless, partitions, deploys the rootfs, and runs the three stages in chroot | **~40 min** |
| `utm` | writes the `.utm` bundle and registers it in UTM | ~1 min |
| `verify` | boots the VM and checks seven conditions inside it: Hyprland and quickshell alive, ≥400 commands, ≤5 broken links, ≥6 `omarchy-*` units, version 4, and the clipboard working end to end. If any fails, the build stops here | ~4 min |
| `sanitize` | copies the disk and strips it for distribution | ~10 min |
| `package` | compacts the qcow2, builds the bundle, and compresses it | ~3 min |

**Total: 76 to 83 minutes**, measured over two full runs on an M3 Max with
the default values — with the 17 tools, with OBS, and with Pinta, which is
exactly what the published image carries — and the result is a **3.6 GB**
`.zip`. Saying no to OBS and Pinta saves about 45 minutes: OBS compiles
entirely from source and is, by far, the most expensive part of the process.

The working directory peaks at about **24 GB**. The script requires 40 GB
free because APFS clones can push it higher.

The `build` phase prints almost nothing while it works. To watch it from
inside:

```bash
tail -f ~/omarchy-arm-build/logs/build.log
```

## 5 · If Something Fails

Every phase is resumable, so **you don't have to start from scratch**:

```bash
./build-omarchy-arm.sh --from build   # resume from there
./build-omarchy-arm.sh --only package # repeat just one phase
./build-omarchy-arm.sh --list         # see the valid names
```

Resuming **doesn't ask again**: what you answered is saved in
`~/omarchy-arm-build/answers.env` and gets picked back up automatically.
Precedence, in this order: what you set in the environment, what's saved,
what's detected from your Mac, and the default — so
`UTM_MEM=16384 ./build-omarchy-arm.sh --from utm` respects your 16384.
`--from` and `--only` are mutually exclusive, and both require a phase name.

Logs live in `~/omarchy-arm-build/logs/`, one per phase. The `build` one is
the one that matters: it carries the full output of the three stages inside
the guest, prefixed `[stage1]`, `[stage2]`, and `[stage3]`.

Two deliberate behaviors worth knowing:

- If a built disk already exists, `build` **doesn't delete it**: it moves it
  to `omarchy-arm.qcow2.previous` and starts a new one.
- If a VM with the same name already exists in UTM, **it doesn't delete it**:
  it registers the new one with the time appended to the name.

And one that can be surprising: for UTM to recognize a new bundle, you have
to restart the app, because it only scans `Documents` on startup. If you have
VMs running, the script warns you and lets you decide; in unattended mode it
doesn't stop them, and instead tells you to import the bundle by hand with
**File → Import**.

## 6 · When It's Done

The VM shows up in UTM. It boots on its own, no password prompt.

**The Option key (⌥) acts as SUPER**, because macOS intercepts Cmd before UTM
receives it. ⌥+Space opens the Omarchy menu, ⌥+Return a terminal, ⌥+K the
full list of shortcuts.

Inside, to install the apps that don't come bundled (1Password, Obsidian,
Typora, LocalSend, Chrome):

```bash
omarchy-arm-extras --list
omarchy-arm-extras            # interactive menu
```

## 7 · To Undo It

```bash
rm -rf ~/omarchy-arm-build           # the entire working directory
```

And delete the VM from UTM's own interface. The script hasn't touched
anything else on your Mac.

---

## If You Just Want the VM

Download **`omarchy-arm-utm-v2.zip`** from https://archive.org/details/omarchy-arm-utm (3.6 GB) and:

```bash
shasum -a 256 -c omarchy-arm-utm-v2.zip.sha256
unzip omarchy-arm-utm-v2.zip
open *.utm
```

User `omarchy`, password `omarchy` (also for root). **Change it as soon as
you log in, with `passwd`.** The rest is in the `README.md` that comes inside
the zip.

Its `sha256` is `929eb816194a5cfc…`. Next to it is an `omarchy-arm-utm.zip`
at 6.5 GB: it's the first release, and it keeps the short name so the links
and checksums published with it keep pointing at the exact bytes they were
written for. That's the only reason the good one carries `-v2` in its name.
`VERSIONS.md` compares the two.
