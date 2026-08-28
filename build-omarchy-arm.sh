#!/usr/bin/env bash
#
#  build-omarchy-arm.sh
#  ────────────────────────────────────────────────────────────────────────────
#  Builds, fully unattended, a UTM virtual machine with Arch Linux ARM (native
#  aarch64, HVF-accelerated) + Hyprland + the Omarchy 4 configuration, and
#  packages it for distribution.
#
#  Omarchy 4 can't be installed on ARM64, but not for the reason usually given.
#  The uname -m guard lives in install/preflight/guard.sh, which exists on
#  master (3.x) and NOT on quattro, where uname -m doesn't appear even once.
#  And its pacman package is arch=('any'): what's x86_64-only is the repo it's
#  published to. What's actually missing is the mirror:
#  stable-mirror.omarchy.org/core/os/aarch64/ returns 404 while x86_64 returns
#  200, and post-install/pacman.sh points pacman there. This script rebuilds
#  the equivalent on Arch Linux ARM and applies the real contents of the
#  Omarchy repository to it.
#
#  Usage:
#    ./build-omarchy-arm.sh                  # all phases
#    ./build-omarchy-arm.sh --from build     # resume from a phase
#    ./build-omarchy-arm.sh --only package   # run a single phase
#    ./build-omarchy-arm.sh --list           # list phases
#
#  Phases:
#    deps      check host dependencies
#    fetch     download the Alpine ISO + ALARM rootfs (with MD5 verification)
#    prepare   compute the package list from Omarchy's live branch
#    build     build the disk (headless, QEMU + HVF, three chroot stages)
#    utm       create the .utm bundle and register it with UTM
#    verify    boot and verify over the serial console
#    sanitize  clean a copy for distribution
#    package   compact, compress and sha256-sign
#
#  Requirements: macOS on Apple Silicon, Homebrew, UTM 4.7+, Command Line
#  Tools (git, python3), and ~40 GB free. No sudo needed.
#  ────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ───────────────────────────────── parameters ──────────────────────────────
# Which variables the environment already carries, BEFORE the ':=' defaults
# below fill them in. Without this there's no way to distinguish "the user
# passed it" from "it's the default", and detect_from_host would overwrite
# whatever the user had set:
# `UTM_MEM=16384 ./build-omarchy-arm.sh --yes` would build with a different figure.
SET_FROM_ENV=""
for _v in VM_TIMEZONE VM_KEYMAP VM_XKB UTM_CPUS UTM_MEM; do
  [ -n "${!_v:-}" ] && SET_FROM_ENV="$SET_FROM_ENV $_v"
done
unset _v
from_env() { case " $SET_FROM_ENV " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

: "${W:=$HOME/omarchy-arm-build}"        # working directory
: "${VM_NAME:=Omarchy ARM}"              # VM name in UTM
: "${VM_USER:=builder}"                  # user during the build
: "${VM_PASSWORD:=builder}"              # prompted; the distributable image renames it
: "${VM_FULLNAME:=Omarchy ARM}"
: "${VM_EMAIL:=user@example.com}"
: "${VM_HOSTNAME:=omarchy}"
: "${VM_TIMEZONE:=Europe/Madrid}"
: "${VM_KEYMAP:=us}"                     # text console
: "${VM_XKB:=us}"                        # Hyprland/Wayland
: "${VM_LOCALE:=en_US.UTF-8}"
: "${VM_LOCALE_EXTRA:=es_ES.UTF-8}"
: "${DISK_SIZE:=80G}"
: "${BUILD_SMP:=8}"                      # vCPUs during the build
: "${BUILD_MEM:=8192}"                   # MiB during the build
: "${UTM_CPUS:=6}"                       # vCPUs of the final VM
: "${UTM_MEM:=6144}"                     # MiB of the final VM
: "${OMARCHY_REF:=quattro}"              # Omarchy branch (NOT master!)
: "${DIST_NEW_USER:=omarchy}"            # user on the distributable image
: "${ALPINE_VER:=v3.24}"
: "${ALPINE_ISO:=alpine-virt-3.24.1-aarch64.iso}"
: "${ALARM_URL:=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"

UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
DOCS="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
PHASES=(deps fetch prepare build utm verify sanitize package)

# ─────────────────────────────────── output ────────────────────────────────
c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_hi=$'\033[1;36m'; c_off=$'\033[0m'
phase() { echo; echo "${c_hi}━━━ $* ━━━${c_off}"; }
info()  { echo "  $*"; }
ok()    { echo "  ${c_ok}✓${c_off} $*"; }
warn()  { echo "  ${c_warn}!${c_off} $*" >&2; }
die()   { echo "  ${c_err}✗ $*${c_off}" >&2; exit 1; }

# ── interaction ─────────────────────────────────────────────────────────────
# The script was born unattended and has to stay that way: without a
# terminal, or with --yes, nothing is asked and the defaults apply. With a
# terminal it asks only what's genuinely a decision, and nothing else.
INTERACTIVE=0
[[ -t 0 && -t 1 ]] && INTERACTIVE=1
[[ -n ${ASSUME_YES:-} ]] && INTERACTIVE=0

# The questionnaire's answers are saved to $W/answers.env so that --from and
# --only don't discard them. Resuming used to regenerate config.env with the
# defaults: the VM ended up with the user 'builder' and its password even if
# the user had typed different ones, with no warning at all.
ANSWER_VARS=(VM_NAME VM_USER VM_PASSWORD VM_FULLNAME VM_EMAIL VM_HOSTNAME
                 VM_TIMEZONE VM_KEYMAP VM_XKB VM_LOCALE VM_LOCALE_EXTRA
                 OMARCHY_REF DIST_NEW_USER DISK_SIZE UTM_CPUS UTM_MEM
                 WANT_TOOLS WANT_EXTRAS WANT_DIST)

shq() { printf "%s" "${1-}" | sed "s/'/'\\\\''/g"; }

save_answers() {
  mkdir -p "$W" 2>/dev/null || return 0
  local v
  for v in "${ANSWER_VARS[@]}"; do
    printf "%s='%s'\n" "$v" "$(shq "${!v-}")"
  done > "$W/answers.env"
}

load_answers() {
  [[ -f "$W/answers.env" ]] || return 0
  # What was saved must NOT override what the user just set in the
  # environment: `UTM_MEM=16384 ./build-omarchy-arm.sh --from utm` has to
  # respect the 16384. It's loaded in a subshell, the values are read, and
  # only the ones that didn't come from the environment get assigned.
  local v val
  for v in "${ANSWER_VARS[@]}"; do
    from_env "$v" && continue
    val=$(. "$W/answers.env" >/dev/null 2>&1; printf '%s' "${!v-}")
    printf -v "$v" '%s' "$val"
  done
  # NOTE: PHASES is NOT touched here. Trimming it at this point broke four
  # things at once -- the worst being that phase-name validation runs BEFORE
  # this, so `--from sanitize` (exactly the escape hatch ph_verify's die
  # suggests) would validate and then run nothing, exiting with rc=0. The
  # trim is decided at the end of main, once the final answer is known.
  return 0
}

ask() {  # ask <variable> <question> [default value]
  local var="$1" q="$2" def="${3:-}" cur ans
  cur="${!var:-$def}"
  if (( ! INTERACTIVE )); then printf -v "$var" '%s' "$cur"; return; fi
  read -r -p "  $q [${cur}]: " ans </dev/tty || ans=""
  printf -v "$var" '%s' "${ans:-$cur}"
}

confirm() {  # confirm <question> <yes|no default>
  local q="$1" def="${2:-yes}" ans
  if (( ! INTERACTIVE )); then [[ $def == yes ]]; return; fi
  read -r -p "  $q [$([[ $def == yes ]] && echo 'Y/n' || echo 'y/N')]: " ans </dev/tty || ans=""
  ans="${ans:-$def}"
  # ${var,,} is bash 4, and macOS ships bash 3.2: there it's an expansion
  # error that aborts the whole function, and confirm would return "yes" by
  # accident.
  ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
  case "$ans" in y|yes) return 0 ;; *) return 1 ;; esac
}

# Defaults are pulled from the Mac itself: that way most questions get
# answered with Enter instead of forcing a lookup of a timezone name. What's
# detected from the Mac is a BETTER DEFAULT, not an order: if the user set the
# variable in the environment, theirs wins. It used to be assigned
# unconditionally, and since unattended mode's `return` comes AFTER this call,
# `UTM_MEM=16384 ./build-omarchy-arm.sh --yes` would end up building with 8192.
detect_from_host() {
  local tz kb ncpu ram
  if ! from_env VM_TIMEZONE; then
    tz=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
    [[ -n $tz ]] && VM_TIMEZONE="$tz"
  fi
  # The two are independent: setting only VM_XKB must not leave VM_KEYMAP on
  # the hardcoded 'es' from the top.
  if ! from_env VM_KEYMAP || ! from_env VM_XKB; then
    kb=$(defaults read ~/Library/Preferences/com.apple.HIToolbox.plist AppleSelectedInputSources 2>/dev/null \
         | sed -n 's/.*"KeyboardLayout Name" = "\([^"]*\)".*/\1/p' | head -1)
    local km="" xk=""
    case "$kb" in
      Spanish*)  km=es; xk=es ;;
      U.S.*|ABC*|US*) km=us; xk=us ;;
      British*)  km=uk; xk=gb ;;
      German*)   km=de; xk=de ;;
      French*)   km=fr; xk=fr ;;
      Portuguese*) km=pt; xk=pt ;;
      Italian*)  km=it; xk=it ;;
    esac
    [[ -n $km ]] && ! from_env VM_KEYMAP && VM_KEYMAP="$km"
    [[ -n $xk ]] && ! from_env VM_XKB    && VM_XKB="$xk"
  fi
  ncpu=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || sysctl -n hw.ncpu)
  ram=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
  from_env UTM_CPUS || { (( ncpu > 2 )) && UTM_CPUS=$(( ncpu / 2 )); }
  if ! from_env UTM_MEM; then
    (( ram >= 16384 )) && UTM_MEM=8192
    (( ram >= 32768 )) && UTM_MEM=12288
  fi
  # BUILD_SMP and BUILD_MEM aren't in the list: they're for the build VM, not
  # the result, and there the point is to squeeze the Mac.
  BUILD_SMP=$(( ncpu > 8 ? 8 : ncpu ))
  (( ram >= 16384 )) && BUILD_MEM=8192
  return 0
}

# ─────────────────────────────── phase: deps ────────────────────────────────
ph_deps() {
  phase "deps · host dependencies"
  [[ $(uname -s) == Darwin ]] || die "this only runs on macOS"
  [[ $(uname -m) == arm64  ]] || die "Apple Silicon required (HVF for aarch64)"
  command -v brew >/dev/null || die "missing Homebrew: https://brew.sh"
  for f in qemu expect aria2; do
    brew list --formula "$f" >/dev/null 2>&1 || { info "installing $f..."; brew install "$f" >/dev/null; }
  done
  command -v qemu-system-aarch64 >/dev/null || die "missing qemu-system-aarch64"
  command -v expect >/dev/null || die "missing expect"
  # git and python3 come from the Command Line Tools, which aren't there on a
  # freshly set up Mac. Used in 'prepare' and in the branch check.
  for c in git python3 zip shasum curl hdiutil; do
    command -v "$c" >/dev/null || die "missing '$c' (did you run 'xcode-select --install'?)"
  done
  [[ -x $UTMCTL ]] || die "missing UTM: brew install --cask utm"
  # Measured on a real build: the disk reaches 9.5 GB, the sanitize copy
  # another 6.5, and the zip 4. With APFS clones the peak is around 30.
  local free; free=$(df -g "$HOME" | tail -1 | awk '{print $4}')
  (( free > 40 )) || die "need ~40 GB free (have ${free} GB)"
  ok "qemu $(qemu-system-aarch64 --version | head -1 | awk '{print $4}'), UTM $(defaults read /Applications/UTM.app/Contents/Info.plist CFBundleShortVersionString), ${free} GB free"
}

# Every phase can run standalone with --only/--from, so the directories can't
# depend on having gone through deps.
ensure_dirs() { mkdir -p "$W"/{dl,vm,provision,scripts,logs,dist,shots}; }

# ─────────────────────────────── phase: fetch ───────────────────────────────
ph_fetch() {
  phase "fetch · base images"
  local iso="$W/dl/alpine-virt-aarch64.iso"
  local tgz="$W/dl/alarm-rootfs.tgz"

  if [[ ! -s $iso ]]; then
    # Alpine PULLS old patches from the CDN once the next one is published, so
    # pinning 3.24.1 expires on its own. The latest virt aarch64 for the
    # branch is resolved by reading the index, with ALPINE_ISO as a fallback.
    local base="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_VER/releases/aarch64"
    local latest
    latest=$(curl -fsSL --max-time 30 "$base/" 2>/dev/null \
             | grep -oE 'alpine-virt-[0-9.]+-aarch64\.iso' | sort -V | tail -1)
    [[ -n $latest ]] || { warn "couldn't read the Alpine index; using $ALPINE_ISO"; latest="$ALPINE_ISO"; }
    info "Alpine $latest (live environment for the bootstrap)"
    aria2c -x8 -s8 -c --file-allocation=none -q -d "$W/dl" -o "$(basename "$iso").partial" \
      "$base/$latest" || die "couldn't download Alpine ($base/$latest)"
    # Verified against the published sha256 before being trusted: an
    # interrupted download leaves a non-empty file that would otherwise
    # always get reused.
    local wsha gsha
    wsha=$(curl -fsSL --max-time 30 "$base/$latest.sha256" 2>/dev/null | awk '{print $1}')
    gsha=$(shasum -a 256 "$W/dl/$(basename "$iso").partial" | awk '{print $1}')
    if [[ -n $wsha && $wsha != "$gsha" ]]; then
      rm -f "$W/dl/$(basename "$iso").partial"
      die "the Alpine ISO doesn't match its published sha256"
    fi
    mv "$W/dl/$(basename "$iso").partial" "$iso"
    [[ -n $wsha ]] && info "sha256 verified" || warn "no published sha256: not verified"
  fi
  ok "Alpine $(du -h "$iso" | cut -f1)"

  if [[ ! -s $tgz ]]; then
    info "Arch Linux ARM rootfs (~800 MB)"
    aria2c -x8 -s8 -c --file-allocation=none -q -d "$W/dl" -o "$(basename "$tgz")" \
      "$ALARM_URL" || die "couldn't download the ALARM rootfs"
  fi
  # The tarball is rebuilt every few weeks: verified against the published MD5.
  local want got
  want=$(curl -fsSL --max-time 30 "$ALARM_URL.md5" | awk '{print $1}')
  got=$(md5 -q "$tgz")
  if [[ -z $want ]]; then
    # This used to announce "MD5 verified" even when the checksum's curl failed.
    warn "couldn't read $ALARM_URL.md5: the rootfs is left UNVERIFIED"
    ok "ALARM rootfs $(du -h "$tgz" | cut -f1), unverified"
  elif [[ $want != "$got" ]]; then
    warn "MD5 mismatch (expected $want, got $got); redownloading"
    rm -f "$tgz"
    [[ ${FETCH_RETRY:-0} -ge 1 ]] && die "the ALARM rootfs still doesn't match after a retry"
    FETCH_RETRY=1 ph_fetch; return
  else
    ok "ALARM rootfs $(du -h "$tgz" | cut -f1), MD5 verified"
  fi
}

# ────────────────────────────── phase: prepare ──────────────────────────────
ph_prepare() {
  phase "prepare · package list"
  # quattro is a pre-release branch: once it's merged or deleted, everything
  # below fails without saying why. Checked ahead of time, falling back to
  # the repository's default branch with a warning.
  if ! git ls-remote --exit-code --heads https://github.com/basecamp/omarchy.git "$OMARCHY_REF" >/dev/null 2>&1; then
    local defref
    defref=$(git ls-remote --symref https://github.com/basecamp/omarchy.git HEAD 2>/dev/null \
             | sed -n 's#^ref: refs/heads/\([^\t ]*\).*#\1#p' | head -1)
    [[ -n $defref ]] || die "branch '$OMARCHY_REF' doesn't exist and I couldn't read Omarchy's default branch"
    warn "branch '$OMARCHY_REF' no longer exists in Omarchy; using '$defref'"
    warn "check whether the structure changed: this build assumes Omarchy 4"
    OMARCHY_REF="$defref"
  fi
  # The list is computed against Omarchy's LIVE branch, intersected with what
  # exists in Arch Linux ARM. Doing it here, rather than with a fixed list,
  # keeps the build from breaking when Omarchy changes packages.
  local base=/tmp/om-base.$$ core=/tmp/alarm-core.$$ extra=/tmp/alarm-extra.$$
  curl -fsSL --max-time 60 \
    "https://raw.githubusercontent.com/basecamp/omarchy/$OMARCHY_REF/install/omarchy-base.packages" \
    -o "$base" || die "couldn't read Omarchy's package list"
  curl -fsSL --max-time 120 http://mirror.archlinuxarm.org/aarch64/core/core.db   -o "$core"  || die "ALARM mirror not responding"
  curl -fsSL --max-time 180 http://mirror.archlinuxarm.org/aarch64/extra/extra.db -o "$extra" || die "ALARM mirror not responding"

  local d=/tmp/alarmdb.$$; rm -rf "$d"; mkdir -p "$d"; ( cd "$d" && tar -xzf "$core"; tar -xzf "$extra" )
  ls -1 "$d" | sed -E 's/-[^-]+-[^-]+$//' | sort -u > /tmp/alarm-pkgs.$$

  # quickshell-git doesn't exist in ALARM; quickshell 0.3.x replaces it.
  # nvim and ttf-jetbrains-mono-nerd-basic are Omarchy's own names for them.
  python3 - "$base" /tmp/alarm-pkgs.$$ "$W/provision" <<'PYEOF'
import sys, pathlib
base, alarm_f, out = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
alarm = set(open(alarm_f).read().split())
subs = {'quickshell-git':'quickshell','ttf-jetbrains-mono-nerd-basic':'ttf-jetbrains-mono-nerd','nvim':'neovim'}
pkgs = [l.strip() for l in open(base) if l.strip() and not l.startswith('#')]
infra = """mesa vulkan-swrast vulkan-icd-loader xorg-xwayland qt6-wayland qt5-wayland
pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber xdg-user-dirs xdg-utils polkit
sddm uwsm hypridle hyprlock hyprpaper hyprshot swaybg wl-clipboard slurp satty
noto-fonts noto-fonts-cjk noto-fonts-emoji terminus-font woff2-font-awesome
go nodejs npm python openssh htop wget curl unzip zip rsync mesa-utils wayland-utils pacman-contrib
phodav davfs2
networkmanager btrfs-progs efibootmgr spice-vdagent qemu-guest-agent""".split()
heavy = set("""libreoffice-fresh kdenlive signal-desktop obs-studio moonlight-qt tesseract
tesseract-data-eng gpu-screen-recorder xournalpp evince system-config-printer cups cups-browsed
cups-filters cups-pdf docker docker-buildx docker-compose rust ruby clang llvm luarocks
mariadb-libs postgresql-libs python-poetry-core tree-sitter-cli usage ufw fcitx5 fcitx5-gtk
fcitx5-qt bolt kernel-modules-hook ffmpegthumbnailer lazydocker firefox dotnet-runtime""".split())
core, ext, miss = [], [], []
for p in pkgs + infra:
    p = subs.get(p, p)
    if p not in alarm: miss.append(p); continue
    (ext if p in heavy else core).append(p)
def dd(xs):
    s=set(); o=[]
    for x in xs:
        if x not in s: s.add(x); o.append(x)
    return o
core, ext = dd(core), dd(ext)
(out/'packages-core.txt').write_text("# core\n"+"\n".join(core)+"\n")
(out/'packages-extra.txt').write_text("# best-effort extras\n"+"\n".join(ext)+"\n")
print(f"  core={len(core)}  extras={len(ext)}  no ARM equivalent={len(set(miss))}")
print("  unavailable:", " ".join(sorted(set(miss))))
PYEOF
  rm -rf "$d" "$base" "$core" "$extra" /tmp/alarm-pkgs.$$
  # Without this a write failure would go unnoticed and the build would die
  # later, far from the cause.
  [ -s "$W/provision/packages-core.txt" ] || die "couldn't write the package lists"
  ok "lists generated against branch '$OMARCHY_REF': $(grep -cvE '^#|^$' "$W/provision/packages-core.txt") in core, $(grep -cvE '^#|^$' "$W/provision/packages-extra.txt") extras"
}

# ─────────────────────────── payloads (written to $W) ──────────────────
write_payloads() {
  # The provisioning files and expect harnesses are materialized here so this
  # script is self-contained: a single file reproduces the whole process.
mkdir -p "$W/provision"
cat > "$W/provision/stage1.sh" <<'__PAYLOAD_PROVISION_STAGE1_SH__'
#!/bin/sh
# Stage 1 — runs in the Alpine live environment (busybox ash).
# Partitions the disk, deploys the Arch Linux ARM rootfs, and enters chroot.
set -eu
PROV=/media/prov
log()  { echo ""; echo "==> [stage1] $*"; }
warn() { echo "!!  [stage1] $*"; }

# Reliable exit marker: piping to tee masks the return code,
# so the script itself emits the token.
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "TOK_BUILD_$rc"' EXIT

log "network"
ip link set eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -t 15 >/dev/null 2>&1 || true
ip -4 addr show eth0 | grep -o 'inet [0-9.]*' || echo "  (no IPv4)"

log "Alpine repositories and tools"
V=$(cut -d. -f1,2 < /etc/alpine-release)
cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/v$V/main
https://dl-cdn.alpinelinux.org/alpine/v$V/community
EOF
apk update >/dev/null
apk add --no-cache parted dosfstools btrfs-progs libarchive-tools e2fsprogs >/dev/null
echo "  ok: $(parted --version | head -1)"

log "loading live kernel filesystem modules"
for m in btrfs vfat fat nls_cp437 nls_iso8859-1 nls_utf8 crc32c-generic xxhash_generic; do
  modprobe "$m" 2>/dev/null || true
done
if grep -qw btrfs /proc/filesystems; then
  ROOTFS=btrfs
else
  warn "btrfs not available in the live kernel -> using ext4 for root"
  ROOTFS=ext4
fi
grep -qw vfat /proc/filesystems || warn "vfat not listed in /proc/filesystems"
echo "  root: $ROOTFS   filesystems: $(tr '\n' ' ' < /proc/filesystems | tr -s ' ')"

log "partitioning $DISK (GPT: ESP 1GiB + root $ROOTFS)"
umount -R /mnt 2>/dev/null || true
wipefs -a "$DISK" >/dev/null 2>&1 || true
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart OMBOOT fat32 1MiB 1025MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart OMROOT "$ROOTFS" 1025MiB 100%
sync; sleep 1
mkfs.vfat -F32 -n OMBOOT "${DISK}1" >/dev/null
if [ "$ROOTFS" = btrfs ]; then
  mkfs.btrfs -f -L OMROOT "${DISK}2" >/dev/null
else
  mkfs.ext4 -qF -L OMROOT "${DISK}2"
fi
sync
parted -s "$DISK" print

MOPT_ROOT=""
if [ "$ROOTFS" = btrfs ]; then
  log "btrfs subvolumes @ and @home"
  mount -t btrfs "${DISK}2" /mnt
  btrfs subvolume create /mnt/@     >/dev/null
  btrfs subvolume create /mnt/@home >/dev/null
  umount /mnt
  MOPT="rw,noatime,compress=zstd:3"
  mount -t btrfs -o "$MOPT,subvol=@" "${DISK}2" /mnt
  mkdir -p /mnt/home
  mount -t btrfs -o "$MOPT,subvol=@home" "${DISK}2" /mnt/home
  MOPT_ROOT="$MOPT,subvol=@"
else
  mount -t ext4 "${DISK}2" /mnt
  mkdir -p /mnt/home
  MOPT_ROOT="rw,noatime"
fi
df -h /mnt

log "deploying Arch Linux ARM rootfs (bsdtar -xpf, preserves xattr/ACL)"
# The ESP is mounted AFTERWARD: vfat doesn't support the symlinks the
# tarball's /boot has. The kernel package repopulates it via pacman in
# stage2, once the ESP is already mounted.
bsdtar -xpf "$PROV/alarm-rootfs.tgz" -C /mnt
echo "  contents: $(ls /mnt | tr '\n' ' ')"
[ -d /mnt/etc ] && [ -d /mnt/usr ] || { warn "incomplete rootfs"; exit 1; }

log "mounting the ESP at /boot"
rm -rf /mnt/boot
mkdir -p /mnt/boot
mount -t vfat "${DISK}1" /mnt/boot
df -h /mnt /mnt/boot

log "chroot mounts"
for d in proc sys dev run tmp; do mkdir -p "/mnt/$d"; done
mount -t proc  none /mnt/proc
mount -t sysfs none /mnt/sys
mount --rbind /dev /mnt/dev
mount --make-rslave /mnt/dev
mount -t tmpfs none /mnt/run
mount -t tmpfs -o size=4G none /mnt/tmp
mkdir -p /mnt/dev/pts && mount -t devpts none /mnt/dev/pts 2>/dev/null || true

log "DNS inside the chroot"
rm -f /mnt/etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /mnt/etc/resolv.conf

log "copying payload"
mkdir -p /mnt/root/prov
cp "$PROV/stage2.sh" "$PROV/stage3.sh" "$PROV/config.env" \
   "$PROV/packages-core.txt" "$PROV/packages-extra.txt" /mnt/root/prov/
[ -f "$PROV/extras.sh" ] && cp "$PROV/extras.sh" /mnt/root/prov/omarchy-arm-extras
[ -f "$PROV/armsync.sh" ] && cp "$PROV/armsync.sh" /mnt/root/prov/10-arm-sync
[ -f "$PROV/clipbrd.sh" ] && cp "$PROV/clipbrd.sh" /mnt/root/prov/omarchy-arm-clipboard
[ -f "$PROV/vdagent.py" ] && cp "$PROV/vdagent.py" /mnt/root/prov/omarchy-arm-vdagent
[ -f "$PROV/share.sh" ] && cp "$PROV/share.sh" /mnt/root/prov/omarchy-arm-share
cat > /mnt/root/prov/fsinfo.env <<EOF
ROOTFS=$ROOTFS
ROOT_MOUNT_OPTS=$MOPT_ROOT
EOF
chmod +x /mnt/root/prov/stage2.sh /mnt/root/prov/stage3.sh

log "entering chroot -> stage2"
set +e
chroot /mnt /bin/bash /root/prov/stage2.sh
rc=$?
set -e

log "unmounting"
sync
umount -R /mnt/tmp /mnt/run /mnt/dev /mnt/sys /mnt/proc 2>/dev/null || true
umount -R /mnt/boot 2>/dev/null || true
umount -R /mnt 2>/dev/null || umount -l /mnt
sync
echo "==> [stage1] finished rc=$rc"
echo "TOK_BUILD_$rc"
trap - EXIT
exit $rc
__PAYLOAD_PROVISION_STAGE1_SH__
chmod +x "$W/provision/stage1.sh"

mkdir -p "$W/provision"
cat > "$W/provision/stage2.sh" <<'__PAYLOAD_PROVISION_STAGE2_SH__'
#!/bin/bash
# Stage 2 — inside the Arch Linux ARM chroot, as root.
# Base system, kernel, UEFI boot, Omarchy stack packages, and login.
set -euo pipefail
. /root/prov/config.env
. /root/prov/fsinfo.env
export LANG=C LC_ALL=C

log()  { echo ""; echo "==> [stage2] $*"; }
warn() { echo "!!  [stage2] $*"; }

trap 'warn "failure at line $LINENO"; exit 1' ERR

# ---------------------------------------------------------------- pacman
log "initializing the Arch Linux ARM keyring"
pacman-key --init
pacman-key --populate archlinuxarm

# A one-hour build can't die because the mirror stalls for ten seconds.
# Actually happened: "failed retrieving file noto-fonts-...: Operation too
# slow. Less than 1 bytes/sec transferred the last 10 seconds" -> the bulk
# install fell over, the one-by-one retry left pipewire-jack out, and the
# stage aborted via its ERR trap, with 40 minutes already spent.
#
# --disable-download-timeout removes that minimum-speed limit, which is what
# aborted it. And a second Server line is added: ALARM's mirrorlist ships only
# the geo-balancer, so if the node you land on is having a bad day there's
# nowhere to fall back to. An extra mirror isn't a risk: pacman verifies each
# package's signature against the archlinuxarm keyring.
if ! grep -q 'de.mirror.archlinuxarm.org' /etc/pacman.d/mirrorlist 2>/dev/null; then
  echo 'Server = http://de.mirror.archlinuxarm.org/$arch/$repo' >> /etc/pacman.d/mirrorlist
fi
# DisableDownloadTimeout goes in pacman.conf, not as a loose flag: that way
# ALL invocations inherit it, including the one makepkg -s runs internally to
# resolve build dependencies.
grep -q '^DisableDownloadTimeout' /etc/pacman.conf \
  || sed -i 's/^\[options\]/[options]\nDisableDownloadTimeout\nParallelDownloads = 5/' /etc/pacman.conf

# Retry wrapper: the mirror fails in bursts, not steadily.
pac() {
  local intento
  for intento in 1 2 3; do
    if pacman -S --noconfirm --needed --disable-download-timeout "$@"; then return 0; fi
    warn "pacman failed (attempt $intento/3); retrying in ${intento}0 s"
    sleep "${intento}0"
    pacman -Sy --noconfirm --disable-download-timeout >/dev/null 2>&1 || true
  done
  return 1
}

log "updating the system (the tarball is from August, the repos are current)"
pacman -Syu --noconfirm --needed --disable-download-timeout \
  || pacman -Syu --noconfirm --needed --disable-download-timeout

log "base system"
# linux-firmware is skipped on purpose: ~800 MB wasted in a VM
pac base base-devel linux-aarch64 \
  sudo git vim networkmanager openssh which man-db man-pages less \
  btrfs-progs dosfstools e2fsprogs efibootmgr \
  rsync wget curl unzip zip

# ---------------------------------------------------------------- localization
log "timezone, locales, keyboard, hostname"
ln -sf "/usr/share/zoneinfo/$VM_TIMEZONE" /etc/localtime
sed -i "s/^#\(${VM_LOCALE} \)/\1/; s/^#\(${VM_LOCALE_EXTRA} \)/\1/" /etc/locale.gen
grep -q "^${VM_LOCALE} " /etc/locale.gen || echo "${VM_LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$VM_LOCALE" > /etc/locale.conf
# Hyprland reads XKBLAYOUT from here (default/hypr/input.lua); KEYMAP only
# covers the text console.
printf 'KEYMAP=%s\nXKBLAYOUT=%s\n' "$VM_KEYMAP" "$VM_XKB" > /etc/vconsole.conf
echo "$VM_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $VM_HOSTNAME.localdomain $VM_HOSTNAME
EOF
systemd-machine-id-setup || true

# ---------------------------------------------------------------- fstab
log "fstab"
if [ "$ROOTFS" = btrfs ]; then
cat > /etc/fstab <<EOF
LABEL=OMROOT  /      btrfs  rw,noatime,compress=zstd:3,subvol=@         0 0
LABEL=OMROOT  /home  btrfs  rw,noatime,compress=zstd:3,subvol=@home     0 0
LABEL=OMBOOT  /boot  vfat   rw,noatime,fmask=0137,dmask=0027,utf8=true  0 2
EOF
KERNEL_ROOTFLAGS="rootflags=subvol=@"
else
cat > /etc/fstab <<EOF
LABEL=OMROOT  /      ext4   rw,noatime                                  0 1
LABEL=OMBOOT  /boot  vfat   rw,noatime,fmask=0137,dmask=0027,utf8=true  0 2
EOF
KERNEL_ROOTFLAGS=""
fi
cat /etc/fstab

# ---------------------------------------------------------------- user
log "user $VM_USER"
userdel -r alarm 2>/dev/null || true
if ! id -u "$VM_USER" >/dev/null 2>&1; then
  useradd -m -G wheel,video,audio,input,storage,network,lp -s /bin/bash -c "$VM_FULLNAME" "$VM_USER"
fi
echo "$VM_USER:$VM_PASSWORD" | chpasswd
echo "root:$VM_PASSWORD"     | chpasswd
install -m 0440 /dev/stdin /etc/sudoers.d/10-wheel <<<'%wheel ALL=(ALL:ALL) ALL'
# no password only for the duration of the install; removed at the end
install -m 0440 /dev/stdin /etc/sudoers.d/99-install <<<"$VM_USER ALL=(ALL:ALL) NOPASSWD: ALL"

# ---------------------------------------------------------------- initramfs
log "mkinitcpio (virtio + btrfs modules)"
sed -i 's/^MODULES=.*/MODULES=(virtio virtio_pci virtio_blk virtio_scsi virtio_net virtio_gpu 9p 9pnet 9pnet_virtio btrfs ext4)/' /etc/mkinitcpio.conf
grep -q '^MODULES=' /etc/mkinitcpio.conf || echo 'MODULES=(virtio virtio_pci virtio_blk virtio_gpu 9p 9pnet_virtio btrfs)' >> /etc/mkinitcpio.conf
mkinitcpio -P
echo "  /boot:"; ls -la /boot

# ---------------------------------------------------------------- UEFI boot
log "systemd-boot on the ESP"
# --no-variables: we don't write to NVRAM; UTM boots via the fallback path
# \EFI\BOOT\BOOTAA64.EFI, which bootctl installs anyway.
bootctl --esp-path=/boot --no-variables install

# The ESP mounts empty AFTER the rootfs is extracted, so /boot has no
# kernel. "pacman -S --needed" won't restore it if the installed version
# already matches the repo's, so the package reinstall is forced.
if [ ! -f /boot/Image ] && [ ! -f /boot/vmlinuz-linux-aarch64 ]; then
  echo "  /boot empty: reinstalling linux-aarch64 to repopulate it"
  pacman -S --noconfirm --disable-download-timeout linux-aarch64 || warn "could not reinstall the kernel"
  mkinitcpio -P || warn "mkinitcpio failed after reinstall"
fi

KERNEL_IMG=""
for c in /boot/Image /boot/vmlinuz-linux-aarch64 /boot/Image.gz; do
  [ -f "$c" ] && { KERNEL_IMG="/$(basename "$c")"; break; }
done
[ -n "$KERNEL_IMG" ] || { warn "can't find the kernel image in /boot"; ls -la /boot; exit 1; }

INITRD=""
for c in /boot/initramfs-linux-aarch64.img /boot/initramfs-linux.img; do
  [ -f "$c" ] && { INITRD="/$(basename "$c")"; break; }
done
[ -n "$INITRD" ] || { warn "can't find the initramfs"; ls -la /boot; exit 1; }

mkdir -p /boot/loader/entries
cat > /boot/loader/loader.conf <<EOF
default  omarchy.conf
timeout  1
console-mode keep
editor   no
EOF
cat > /boot/loader/entries/omarchy.conf <<EOF
title    Arch Linux ARM — Omarchy
linux    $KERNEL_IMG
initrd   $INITRD
options  root=LABEL=OMROOT $KERNEL_ROOTFLAGS rw quiet loglevel=3
EOF
cat > /boot/loader/entries/omarchy-verbose.conf <<EOF
title    Arch Linux ARM — Omarchy (verbose)
linux    $KERNEL_IMG
initrd   $INITRD
options  root=LABEL=OMROOT $KERNEL_ROOTFLAGS rw
EOF
echo "  kernel=$KERNEL_IMG initrd=$INITRD"
echo "  ESP:"; find /boot/EFI /boot/loader -maxdepth 3 | sort

# ---------------------------------------------------------------- network
log "network: NetworkManager (disabling the tarball's systemd-networkd)"
systemctl disable systemd-networkd.service systemd-networkd.socket 2>/dev/null || true
systemctl disable systemd-resolved.service 2>/dev/null || true
rm -f /etc/systemd/network/*.network 2>/dev/null || true
systemctl enable NetworkManager.service
systemctl enable systemd-timesyncd.service 2>/dev/null || true

# ---------------------------------------------------------------- desktop
log "installing the desktop stack (Hyprland + Omarchy tools)"
install_list() {
  local file="$1" label="$2" fatal="$3"
  mapfile -t PKGS < <(grep -vE '^\s*#|^\s*$' "$file")
  echo "  $label: ${#PKGS[@]} packages"
  if pac "${PKGS[@]}"; then return 0; fi
  warn "$label: bulk install failed after 3 attempts; trying one by one"
  local FAILED=()
  for p in "${PKGS[@]}"; do
    pacman -S --noconfirm --needed --disable-download-timeout "$p" >/dev/null 2>&1 && continue
    # Second pass on whatever fails: it's almost always the mirror, not the package.
    sleep 3
    pacman -S --noconfirm --needed --disable-download-timeout "$p" >/dev/null 2>&1 || FAILED+=("$p")
  done
  if [ ${#FAILED[@]} -gt 0 ]; then
    warn "$label not installed: ${FAILED[*]}"
    printf '%s\n' "${FAILED[@]}" >> /root/failed-packages.txt
    [ "$fatal" = fatal ] && return 1
  fi
  return 0
}
install_list /root/prov/packages-core.txt  "core" fatal
set +e
install_list /root/prov/packages-extra.txt "extras" soft
set -e

log "system services"
systemctl enable sddm.service 2>/dev/null || warn "sddm not available"
# UTM integration: utmctl ip-address/exec/file need the guest agent
systemctl enable qemu-guest-agent.service 2>/dev/null || true
# The Arch Linux ARM rootfs ships with sshd started, and here we install
# openssh and set the same trivial password on both the user and root. A
# personal VM (without the sanitize phase, which was the only place this got
# disabled) would sit there listening with omarchy/omarchy. It's turned off by
# default; whoever wants it:
#   sudo systemctl enable --now sshd
systemctl disable sshd.service 2>/dev/null || true
systemctl disable sshd.socket  2>/dev/null || true
# The SPICE clipboard has THREE pieces, not two:
#   SPICE client (UTM) <-virtio port-> spice-vdagentd <-unix socket-> agent
# The daemon is what talks to the host; the session agent only talks to the
# daemon. That's why spice-vdagentd has to stay alive even though its official
# agent (X11) doesn't work under Hyprland: what gets replaced is the agent,
# not the daemon.
#
# And -X is required: the "active seat0 session" check (vdagentd.c:746,
# systemd-login.c:272) fails with Hyprland launched by SDDM, and then the
# daemon silently drops the clipboard.
mkdir -p /etc/systemd/system/spice-vdagentd.service.d
cat > /etc/systemd/system/spice-vdagentd.service.d/override.conf <<'OVR'
[Service]
# -X: no logind integration. Without this the daemon can't find "the active
# seat0 session" under Hyprland and silently drops the clipboard.
ExecStart=
ExecStart=/usr/bin/spice-vdagentd -X -x -f
OVR
systemctl enable spice-vdagentd.service 2>/dev/null || true
systemctl enable spice-vdagentd.socket 2>/dev/null || true
echo "  spice-vdagentd with -X (required under Hyprland)"

# NO udev rule is installed for /dev/virtio-ports/com.redhat.spice.0.
# There used to be one, and it was wrong twice over: omarchy-arm-vdagent never
# opens that port —it talks over the unix socket
# /run/spice-vdagentd/spice-vdagent-sock, as stage3 itself explains— and the
# port is opened exclusively by the daemon. Giving the seat user ACL with
# TAG+="uaccess" only made it possible for something else to take it away from
# the daemon and leave it with no channel ("Device or resource busy"), which
# is exactly the first dead end in this problem.
# MODE="0660" also did nothing: without GROUP= the group stays root.

# UTM's shared folder has TWO modes and the user picks which one:
#   VirtFS → 9p device with mount_tag "share"
#   SPICE WebDAV → virtio port org.spice-space.webdav.0, served by
#     spice-webdavd (phodav package) at http://localhost:9843/
# Both are prepared: each one activates only if its device exists.
systemctl enable spice-webdavd.service 2>/dev/null || true
echo "  spice-webdavd enabled (UTM's SPICE WebDAV mode)"

# UTM shared folder. The bundle declares DirectoryShareMode=VirtFS, but that
# only exposes the device: the guest still has to mount it. The tag is
# "share" (UTM, Configuration/UTMQemuConfiguration+Arguments.swift:1234).
# nofail so a boot without a configured folder doesn't drop to emergency mode,
# and x-systemd.automount so the mount isn't paid for if unused.
mkdir -p /mnt/share
# The fstab entry only works for VirtFS, and the user may have chosen SPICE
# WebDAV instead. Rather than pin one mode, omarchy-arm-share is installed,
# which detects which one is active. The fstab entry is kept anyway with
# nofail: if the 9p device exists, it mounts automatically at boot.
if ! grep -q '^share ' /etc/fstab; then
  cat >> /etc/fstab <<'FSTAB'

# UTM shared folder in VirtFS mode. If you picked SPICE WebDAV, this line
# does nothing (nofail) and omarchy-arm-share mounts it instead.
share  /mnt/share  9p  trans=virtio,version=9p2000.L,rw,nofail,x-systemd.automount,_netdev,msize=512000  0  0
FSTAB
fi
echo "  /mnt/share ready (VirtFS via fstab, WebDAV via omarchy-arm-share)"
systemctl enable bluetooth.service 2>/dev/null || true
systemctl enable docker.service 2>/dev/null || true
usermod -aG docker "$VM_USER" 2>/dev/null || true

# ---------------------------------------------------------------- dotfiles
log "stage 3: Omarchy dotfiles as $VM_USER"
chmod +x /root/prov/stage3.sh
install -d -o "$VM_USER" -g "$VM_USER" "/home/$VM_USER"
# stage3 runs as a regular user and /root is 0750: any test it runs against
# /root/prov comes back false without erroring. It gets a readable copy in
# its home instead.
PROVDIR="/home/$VM_USER/.omarchy-arm-prov"
mkdir -p "$PROVDIR"
for f in omarchy-arm-extras 10-arm-sync omarchy-arm-clipboard omarchy-arm-vdagent omarchy-arm-share; do
  [ -f "/root/prov/$f" ] && install -m 0644 "/root/prov/$f" "$PROVDIR/$f"
done
cp /root/prov/stage3.sh /root/prov/config.env "/home/$VM_USER/"
chown -R "$VM_USER:$VM_USER" "$PROVDIR"
chown "$VM_USER:$VM_USER" "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
echo "  available to stage3: $(ls "$PROVDIR" | tr '\n' ' ')"
# stage3's result has to reach the host: it used to just degrade to a warn and
# stage2 emitted its success token regardless, so a stage3 that failed
# entirely produced a disk with not one single Omarchy dotfile, declared OK.
# WATCH OUT: with `set -e` + trap ERR, writing `su ...; RC=$?` does NOT work:
# if su returns != 0 the trap fires and the stage dies BEFORE the assignment,
# so the TOK_STAGE3_<rc> token was only ever emitted for the 0 case and the
# host never got to see stage3's actual failure. With `|| RC=$?` the command
# is in tested context and set -e doesn't step in.
STAGE3_RC=0
su - "$VM_USER" -c "bash ~/stage3.sh" || STAGE3_RC=$?
[ $STAGE3_RC -eq 0 ] || warn "stage3 finished with errors (rc=$STAGE3_RC)"
echo "TOK_STAGE3_$STAGE3_RC"
rm -f "/home/$VM_USER/stage3.sh" "/home/$VM_USER/config.env"
rm -rf "$PROVDIR"

# ---------------------------------------------------------------- SDDM login
log "SDDM: Omarchy session with autologin"
OM="/home/$VM_USER/.local/share/omarchy"
mkdir -p /usr/local/share/wayland-sessions /etc/sddm.conf.d /usr/share/sddm
if [ -f "$OM/default/wayland-sessions/omarchy.desktop" ]; then
  cp "$OM/default/wayland-sessions/omarchy.desktop" /usr/local/share/wayland-sessions/omarchy.desktop
  SESSION=omarchy
else
  SESSION=hyprland-uwsm
fi
[ -f "$OM/default/sddm/hyprland.conf" ] && cp "$OM/default/sddm/hyprland.conf" /usr/share/sddm/hyprland.conf
cat > /etc/sddm.conf.d/10-wayland.conf <<EOF
[General]
DisplayServer=wayland
EOF
cat > /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$VM_USER
Session=$SESSION
EOF
sed -i '/-auth.*pam_gnome_keyring\.so/d;/-password.*pam_gnome_keyring\.so/d' /etc/pam.d/sddm 2>/dev/null || true
echo "  session=$SESSION"
ls /usr/local/share/wayland-sessions /usr/share/wayland-sessions 2>/dev/null

# ---------------------------------------------------------------- VM settings
log "VM-specific settings"
# Hardware cursor and DRM modifiers cause problems on virtio-gpu
mkdir -p /etc/environment.d
cat > /etc/environment.d/90-vm-graphics.conf <<'EOF'
# virtio-gpu (virgl) under UTM/QEMU
WLR_NO_HARDWARE_CURSORS=1
AQ_NO_MODIFIERS=1
WLR_RENDERER_ALLOW_SOFTWARE=1
# Without this, GPU client windows (alacritty, chromium) get mapped but NOT
# painted: virgl doesn't hand over buffers Hyprland can composite. Only
# clients using wl_shm (foot) render. Everything works with llvmpipe.
# Confirmed NOT to fix it: AQ_NO_MODIFIERS, render:cm_enabled=false,
# render:explicit_sync (removed in Hyprland 0.56).
LIBGL_ALWAYS_SOFTWARE=1
EOF
# serial console useful for debugging from the host
systemctl enable serial-getty@ttyAMA0.service 2>/dev/null || true

log "cleanup"
rm -f /etc/sudoers.d/99-install
paccache -rk1 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true

log "summary"
echo "  kernel:    $(pacman -Q linux-aarch64 2>/dev/null || echo '?')"
echo "  hyprland:  $(pacman -Q hyprland 2>/dev/null || echo 'NOT INSTALLED')"
echo "  sddm:      $(pacman -Q sddm 2>/dev/null || echo 'NOT INSTALLED')"
echo "  mesa:      $(pacman -Q mesa 2>/dev/null || echo '?')"
echo "  user:      $(id "$VM_USER")"
echo "  dotfiles:  $(ls -d /home/$VM_USER/.config/hypr 2>/dev/null || echo 'MISSING')"
sync
touch /root/STAGE2_OK
echo ""
echo "==> [stage2] COMPLETE"
__PAYLOAD_PROVISION_STAGE2_SH__
chmod +x "$W/provision/stage2.sh"

mkdir -p "$W/provision"
cat > "$W/provision/stage3.sh" <<'__PAYLOAD_PROVISION_STAGE3_SH__'
#!/bin/bash
# Stage 3 — as a regular user inside the chroot.
# Omarchy dotfiles, theme, and the pieces that only exist in AUR.
set -uo pipefail   # no -e: this stage is best-effort in parts
. ~/config.env

log()  { echo ""; echo "==> [stage3] $*"; }
warn() { echo "!!  [stage3] $*"; }

export OMARCHY_PATH="$HOME/.local/share/omarchy"
export OMARCHY_INSTALL="$OMARCHY_PATH/install"
export PATH="$OMARCHY_PATH/bin:$PATH:$HOME/.local/bin"
export OMARCHY_CHROOT_INSTALL=1

# ------------------------------------------------------------ Omarchy repo
log "cloning basecamp/omarchy (branch ${OMARCHY_REF:-quattro} = Omarchy 4; master is 3.8.5)"
rm -rf "$OMARCHY_PATH"
mkdir -p "$(dirname "$OMARCHY_PATH")"
git clone --depth 1 --branch "${OMARCHY_REF:-quattro}" https://github.com/basecamp/omarchy.git "$OMARCHY_PATH" || { warn "clone failed"; exit 1; }
# core.fileMode=false BEFORE the chmod: otherwise the permission changes leave the
# checkout dirty and `git pull --ff-only` refuses to update it afterward.
git -C "$OMARCHY_PATH" config core.fileMode false
find "$OMARCHY_PATH/bin" -type f -exec chmod +x {} \; 2>/dev/null
echo "  version: $(cat "$OMARCHY_PATH/version" 2>/dev/null)"

# ------------------------------------------------------------ dotfiles
# Equivalent to install/config/config.sh
log "copying dotfiles to ~/.config"
mkdir -p ~/.config
cp -R "$OMARCHY_PATH"/config/* ~/.config/
cp "$OMARCHY_PATH/default/bashrc" ~/.bashrc
ls ~/.config | tr '\n' ' '; echo

# ------------------------------------------------------------ AUR
log "AUR: Omarchy pieces not present in the Arch Linux ARM repos"
mkdir -p /tmp/aur
aur_install() {
  local p="$1"
  echo "  --- $p"
  rm -rf "/tmp/aur/$p"
  git clone --depth 1 -q "https://aur.archlinux.org/$p.git" "/tmp/aur/$p" || { warn "clone $p"; return 1; }
  ( cd "/tmp/aur/$p" && makepkg -si --noconfirm --needed --noprogressbar ) >"/tmp/aur/$p.log" 2>&1 \
    || { warn "makepkg $p failed (log: /tmp/aur/$p.log)"; tail -15 "/tmp/aur/$p.log"; return 1; }
  echo "  ok: $p"
}

AUR_OK=(); AUR_KO=()
# xdg-terminal-exec resolves $TERMINAL. walker and elephant are NOT installed:
# quattro retires them (see bin/omarchy-upgrade-to-quattro); the launcher and the
# menu are quickshell panels (`omarchy-shell shell toggle omarchy.menu`).
for p in yay xdg-terminal-exec; do
  if aur_install "$p"; then AUR_OK+=("$p"); else AUR_KO+=("$p"); fi
done
echo "  AUR ok:     ${AUR_OK[*]:-none}"
echo "  AUR failed: ${AUR_KO[*]:-none}"

# Fallback if xdg-terminal-exec fails to build: Omarchy uses $TERMINAL=xdg-terminal-exec
if ! command -v xdg-terminal-exec >/dev/null 2>&1; then
  warn "xdg-terminal-exec missing: installing a wrapper around alacritty"
  sudo install -m 0755 /dev/stdin /usr/local/bin/xdg-terminal-exec <<'EOF'
#!/bin/sh
# Minimal wrapper: Omarchy exports TERMINAL=xdg-terminal-exec.
# The fallback is foot, which IS in quattro's omarchy-base.packages
# (alacritty is NOT: pointing there left $TERMINAL broken).
T=$(command -v foot || command -v alacritty || command -v xterm) || exit 127
if [ "$#" -eq 0 ]; then exec "$T"; fi
exec "$T" -e "$@"
EOF
fi

# Default terminal: Omarchy prefers ghostty, which doesn't exist for aarch64.
# The fallback is foot, which IS in quattro's omarchy-base.packages (and
# alacritty is NOT: it's in neither that list nor the infra one). Naming
# Alacritty.desktop here pointed to a .desktop that doesn't exist in the image, and
# xdg-terminal-exec ended up choosing by elimination. They're listed by preference
# and only the ones that are actually installed.
: > ~/.config/xdg-terminals.list
# Literal names, no ${t^}: that's bash 4, and even though bash 5 is present in here,
# it's not worth leaving a bash-4-ism in a payload that's also read on a
# Mac with bash 3.2.
for f in com.mitchellh.ghostty.desktop ghostty.desktop \
         foot.desktop Alacritty.desktop alacritty.desktop xterm.desktop; do
  for d in /usr/share/applications /usr/local/share/applications "$HOME/.local/share/applications"; do
    [ -f "$d/$f" ] && { echo "$f" >> ~/.config/xdg-terminals.list; break; }
  done
done
[ -s ~/.config/xdg-terminals.list ] || printf 'foot.desktop\n' > ~/.config/xdg-terminals.list
echo "  preferred terminal: $(head -1 ~/.config/xdg-terminals.list)"

# ------------------------------------------------ system integration
# Omarchy 4 is distributed as a pacman package that places the tree at
# /usr/share/omarchy, the binaries in the system PATH, and hooks in
# /etc/profile.d and /usr/share/uwsm/env.d. That package only exists for x86_64,
# so it's replicated by hand here. Without this OMARCHY_PATH stays empty and Hyprland
# boots into emergency mode because it can't find default/hypr/bootstrap.lua.
log "integrating Omarchy into system paths (replaces the pacman package)"
sudo ln -sfn "$OMARCHY_PATH" /usr/share/omarchy
# The commands go to /usr/bin, which is where upstream's package() puts them.
# Putting them in /usr/local/bin seemed cleaner (no clash with pacman) but
# it breaks things: the tree has 13 /usr/bin/omarchy-* paths hardcoded, five of
# them in .service files. enable-user-units.sh used to fail because of that, and since
# first-run is only marked done if NO step fails, it repeated on every login,
# resending the "Update System" notice forever.
# Checked: none of the 433 names collides with an ALARM package.
sudo mkdir -p /usr/bin
# The links point to /usr/share/omarchy, NOT to $OMARCHY_PATH. Here they're the
# same thing (the former is a symlink to the latter), but the sanitizer
# turns /usr/share/omarchy into a real directory and renames the user: a
# link to /home/<builder>/... is left dangling and takes down the 433
# commands with it. /usr/share/omarchy is the only stable path of the two.
n=0
for f in "$OMARCHY_PATH"/bin/*; do
  [ -f "$f" ] || continue
  chmod +x "$f"
  sudo ln -sfn "/usr/share/omarchy/bin/$(basename "$f")" "/usr/bin/$(basename "$f")" && n=$((n+1))
done
echo "  $n binaries in /usr/bin -> /usr/share/omarchy/bin"
# User units go to /usr/lib/systemd/user/, which is where systemd
# looks for them. They're installed by the omarchy-settings package, which also doesn't exist for ARM.
# Without this, install/user/first-run/enable-user-units.sh fails on every login, and
# since omarchy-provision-first-run is only marked done if NO step fails, the
# first-run repeats indefinitely, resending the "Update System" notice.
# Source: docs/file-layout.md, "systemd/user/*.service → /usr/lib/systemd/user/".
if [ -d "$OMARCHY_PATH/default/systemd/user" ]; then
  sudo install -d /usr/lib/systemd/user
  sudo cp -a "$OMARCHY_PATH/default/systemd/user/." /usr/lib/systemd/user/
  echo "  $(ls "$OMARCHY_PATH/default/systemd/user"/*.service 2>/dev/null | wc -l) user units in /usr/lib/systemd/user"
fi
for d in system-sleep zram-generator.conf.d; do
  [ -d "$OMARCHY_PATH/default/systemd/$d" ] && \
    sudo cp -a "$OMARCHY_PATH/default/systemd/$d" /usr/lib/systemd/ 2>/dev/null || true
done
sudo install -Dm644 "$OMARCHY_PATH/etc/profile.d/omarchy.sh" /etc/profile.d/omarchy.sh
sudo install -Dm644 "$OMARCHY_PATH/default/uwsm/env.d/10-omarchy" /usr/share/uwsm/env.d/10-omarchy
sudo cp -a "$OMARCHY_PATH/etc/sysctl.d/." /etc/sysctl.d/ 2>/dev/null || true
sudo cp -a "$OMARCHY_PATH/etc/security/." /etc/security/ 2>/dev/null || true
for d in system.conf.d user.conf.d logind.conf.d oomd.conf.d; do
  [ -d "$OMARCHY_PATH/etc/systemd/$d" ] && sudo cp -a "$OMARCHY_PATH/etc/systemd/$d" /etc/systemd/ 2>/dev/null || true
done
[ -d "$OMARCHY_PATH/etc/fastfetch" ] && sudo cp -a "$OMARCHY_PATH/etc/fastfetch" /etc/ 2>/dev/null || true
[ -d "$OMARCHY_PATH/etc/gnupg" ] && sudo cp -a "$OMARCHY_PATH/etc/gnupg/." /etc/gnupg/ 2>/dev/null || true
# systemd-oomd comes configured in etc/systemd/oomd.conf.d but needs
# to be enabled; NetworkManager-wait-online delays boot without adding anything
# in a VM with user-mode networking.
sudo systemctl enable systemd-oomd.service 2>/dev/null || true
sudo systemctl mask NetworkManager-wait-online.service 2>/dev/null || true
# gnome-keyring in SDDM's PAM blocks autologin without a keyring configured
for pf in /etc/pam.d/sddm /etc/pam.d/sddm-autologin /etc/pam.d/sddm-greeter; do
  [ -f "$pf" ] && sudo sed -i '/-auth.*pam_gnome_keyring\.so/d;/-password.*pam_gnome_keyring\.so/d' "$pf"
done

log "SDDM: Omarchy theme and session"
sudo mkdir -p /usr/share/sddm/themes /usr/local/share/wayland-sessions
sudo cp -a "$OMARCHY_PATH/default/sddm/omarchy" /usr/share/sddm/themes/ 2>/dev/null || true
[ -f "$OMARCHY_PATH/default/sddm/hyprland.lua" ] && sudo cp -a "$OMARCHY_PATH/default/sddm/hyprland.lua" /usr/share/sddm/hyprland.lua
sudo install -Dm644 "$OMARCHY_PATH/etc/sddm.conf.d/10-theme.conf"   /etc/sddm.conf.d/10-theme.conf
sudo install -Dm644 "$OMARCHY_PATH/etc/sddm.conf.d/10-wayland.conf" /etc/sddm.conf.d/10-wayland.conf
sudo install -Dm644 "$OMARCHY_PATH/default/wayland-sessions/omarchy.desktop" /usr/local/share/wayland-sessions/omarchy.desktop
sudo bash "$OMARCHY_PATH/install/config/theme-system.sh" 2>&1 | tail -2 || true

export OMARCHY_PATH=/usr/share/omarchy
export PATH="/usr/local/bin:$PATH"

# ------------------------------------------------------------ theme
log "applying the Tokyo Night theme"
mkdir -p ~/.config/omarchy/themes
if command -v omarchy-theme-set >/dev/null 2>&1; then
  omarchy-theme-set "Tokyo Night" || warn "omarchy-theme-set failed; linking manually"
fi
if [ ! -e ~/.config/omarchy/current/theme ]; then
  mkdir -p ~/.config/omarchy/current
  ln -snf "$OMARCHY_PATH/themes/tokyo-night" ~/.config/omarchy/current/theme
fi
# Per-app theme links. In quattro the active theme lives at
# ~/.local/state/omarchy/current/theme (bin/omarchy-theme-set:12), not at
# ~/.config/omarchy/current, which is the Omarchy 3 path and doesn't exist here.
# There's no mako link: quattro has no external notification daemon.
mkdir -p ~/.config/btop/themes
ln -snf ~/.local/state/omarchy/current/theme/btop.theme ~/.config/btop/themes/current.theme
ls -l ~/.local/state/omarchy/current/ 2>/dev/null

# ------------------------------------------------------------ VM settings
log "settings for the virtual machine"
# quattro uses Lua configuration: writing monitors.conf would be pointless.
cat > ~/.config/hypr/monitors.lua <<'LUA'
-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- Available modes: hyprctl monitors all
--
-- VM in UTM/QEMU with virtio-gpu. Two changes from Omarchy's defaults:
--
--  1. Scale 1 (Omarchy assumes retina 2x screens; in the VM that makes everything huge).
--  2. Fixed resolution 1920x1200 instead of "preferred", which gives 1280x800.
--
-- IMPORTANT: changing the mode LIVE (hyprctl / config reload) breaks
-- rendering under virgl: the desktop goes blank until reboot.
-- Applied at boot it works fine. If you touch this, reboot the VM.
--
-- To make the resolution follow the size of the UTM window:
--   hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.env("GDK_SCALE", "1")
hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })
LUA
rm -f ~/.config/hypr/monitors.conf ~/.config/hypr/autostart.conf

# Clipboard shared with the UTM host
cat > ~/.config/hypr/autostart.lua <<'LUA'
-- Extra processes at session start.
hl.on("hyprland.start", function()
  -- spice-vdagent is NOT launched: its clipboard is X11 and under Hyprland it dies
  -- with "cannot open display". Worse still, if it starts, vdagentd sees two agents
  -- in the same session and disconnects both ("multiple agents in one
  -- session"). The clipboard is handled by omarchy-arm-vdagent, as a
  -- user service.
end)
LUA

# --- seal migrations: a clean install starts already in the final state -------
# Without this omarchy-update tries to replay ~80 historical migrations and dies
# on the first one that installs an Omarchy-specific package (x86_64 only).
mkdir -p ~/.local/state/omarchy/migrations
for f in "$OMARCHY_PATH"/migrations/*.sh; do
  [ -f "$f" ] && : > ~/.local/state/omarchy/migrations/"$(basename "$f")"
done
echo "  migrations sealed: $(ls -1 ~/.local/state/omarchy/migrations | wc -l)"

# --- branding (about + screensaver) -----------------------------------
mkdir -p ~/.config/omarchy/branding
cp "$OMARCHY_PATH/icon.txt" ~/.config/omarchy/branding/about.txt 2>/dev/null || true
cp "$OMARCHY_PATH/logo.txt" ~/.config/omarchy/branding/screensaver.txt 2>/dev/null || true

# --- omarchy-pkg-add tolerant of what doesn't exist on ARM ---------------
# CRITICAL: /usr/local/bin/omarchy-pkg-add is a symlink into the tree. Writing with
# `tee` would follow it and replace Omarchy's ORIGINAL script with this
# wrapper, whose REAL would then point to itself: infinite loop. The symlink
# must be deleted and a real file created instead.
sudo rm -f /usr/local/bin/omarchy-pkg-add
sudo install -Dm755 /dev/stdin /usr/local/bin/omarchy-pkg-add <<'WRAP'
#!/bin/bash
# Wrapper for Arch Linux ARM: Omarchy-specific packages (tensaku,
# omarchy-nvim, ttfx...) and several proprietary apps only exist for x86_64.
# The original aborts if any is missing, which takes down omarchy-update entirely and leaves
# migrations half-done. Here they're skipped with a warning and the rest gets installed.
REAL=/usr/share/omarchy/bin/omarchy-pkg-add
avail=(); skip=()
for p in "$@"; do
  if pacman -Q "$p" &>/dev/null || pacman -Si "$p" &>/dev/null; then
    avail+=("$p")
  else
    skip+=("$p")
  fi
done
((${#skip[@]})) && printf '\033[33mSkipped, not available on Arch Linux ARM: %s\033[0m\n' "${skip[*]}" >&2
((${#avail[@]})) || exit 0
exec "$REAL" "${avail[@]}"
WRAP

# --- Omarchy tools that aren't published for aarch64 -------------
# Almost none of them are actually incompatible: they're Rust, Go, or Qt/C++ and just need
# someone to build them. Several declare arch=(x86_64) by default, not because
# the code isn't portable; in those cases it's enough to add the architecture.
# They're built in order of increasing cost, and none is fatal if it fails.
build_omarchy_tool() {                 # build_omarchy_tool <aur|omapkgs> <pkg>
  # A single `local` expands all the values before assigning any of them,
  # so $pkg doesn't exist yet when building $dir. They have to be kept separate.
  local src="$1" pkg="$2"
  local dir="/tmp/omabuild/$pkg"
  pacman -Q "$pkg" >/dev/null 2>&1 && return 0
  rm -rf "$dir"; mkdir -p "$dir"
  case "$src" in
    aur)
      # AUR URLs use the PackageBase, which isn't always the package name
      # (yaru-icon-theme lives in the "yaru" repo).
      local base
      base=$(curl -fsSL --max-time 20 "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" \
             | sed -n 's/.*"PackageBase":"\([^"]*\)".*/\1/p' | head -1)
      [ -n "$base" ] || base="$pkg"
      git clone -q "https://aur.archlinux.org/$base.git" "$dir" 2>/dev/null || return 1 ;;
    omapkgs)
      git clone --depth 1 --filter=blob:none --sparse -q \
        https://github.com/omacom-io/omarchy-pkgs.git "$dir/repo" || return 1
      ( cd "$dir/repo" && git sparse-checkout set "pkgbuilds/$pkg" >/dev/null 2>&1 )
      cp -a "$dir/repo/pkgbuilds/$pkg/." "$dir/" 2>/dev/null || return 1
      rm -rf "$dir/repo" ;;
  esac
  [ -f "$dir/PKGBUILD" ] || return 1
  # 'any' can appear unquoted; mixing it with specific architectures is a
  # makepkg error, so it's only patched when it's neither 'any' nor already has aarch64.
  grep -qE "^arch=\(.*\b(aarch64|any)\b" "$dir/PKGBUILD" || \
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
  # A PKGBUILD can produce several subpackages, and only one of them might have
  # a dependency missing on ARM (yaru-gtk-theme needs gtk-engine-murrine).
  # It's built without installing, then only the requested subpackage is installed.
  # -s installs the build dependencies. Without it, most of these
  # PKGBUILDs fail at the first step due to missing makedepends. -i isn't used
  # because installation happens afterward, subpackage by subpackage.
  # If it fails, the log is the only thing that explains why, and until now it was lost
  # by the `rm -rf /tmp/omabuild` two lines below: the build
  # would say "failed to build: X" with no way to find out anything more.
  # The speed limit is removed by DisableDownloadTimeout in /etc/pacman.conf
  # (stage2 sets it): that way the pacman that makepkg -s launches for
  # its dependencies inherits it too. Passing it through the PACMAN variable doesn't work, because makepkg
  # invokes it quoted, and a string with arguments gets looked up as if it were the
  # name of the executable.
  if ( cd "$dir" && makepkg -s --noconfirm --needed --noprogressbar --nocheck ) >"$dir/build.log" 2>&1; then
    local built
    built=$(ls "$dir/$pkg"-*.pkg.tar.* 2>/dev/null | head -1)
    [ -n "$built" ] || built=$(ls "$dir"/*.pkg.tar.* 2>/dev/null | head -1)
    # theme-system.sh already created symlinks inside /usr/share/icons/Yaru because the
    # theme wasn't there: the real package collides with them. --overwrite resolves it.
    [ -n "$built" ] && sudo pacman -U --noconfirm --needed \
      --overwrite '/usr/share/icons/*' "$built" >>"$dir/build.log" 2>&1
  else
    mkdir -p "$HOME/.omarchy-arm-prov/fallos"
    cp "$dir/build.log" "$HOME/.omarchy-arm-prov/fallos/$pkg.log" 2>/dev/null || true
    echo "  --- $pkg failed; last lines from makepkg ---"
    tail -20 "$dir/build.log" 2>/dev/null | sed 's/^/      /'
    echo "  --- (full log at ~/.omarchy-arm-prov/fallos/$pkg.log) ---"
    return 1
  fi
}

# Some PKGBUILDs invoke zig by a fixed, versioned path (/opt/zig0.15/zig).
# On ARM there's only one zig version, so it's linked wherever they look for it.
if pacman -Si zig >/dev/null 2>&1; then
  sudo pacman -S --noconfirm --needed --disable-download-timeout zig >/dev/null 2>&1 || true
  for v in zig0.15 zig0.14; do
    sudo mkdir -p "/opt/$v" && sudo ln -sfn "$(command -v zig)" "/opt/$v/zig" 2>/dev/null || true
  done
fi

if [ "${WANT_TOOLS:-yes}" != "yes" ]; then
  warn "tool compilation disabled: ttfx, tensaku, omacalc,"
  warn "omacut, omawrite, aether, cliamp, and omarchy-nvim will be missing (they can be added later"
  warn "with: yay -S <package>)"
else
log "building the Omarchy tools missing on aarch64"
TOOLS_OK=(); TOOLS_KO=()
for spec in \
  "aur:yaru-icon-theme" "aur:ttf-ia-writer" "aur:tzupdate" "aur:ufw-docker" \
  "omapkgs:omarchy-nvim" "omapkgs:tobi-try" "aur:mise-bin" \
  "aur:aether" "aur:cliamp" \
  "omapkgs:omacalc" "omapkgs:omacut" "omapkgs:omawrite" \
  "aur:herdr" "omapkgs:tensaku" "omapkgs:hyprland-preview-share-picker"; do
  src=${spec%%:*}; pkg=${spec#*:}
  if build_omarchy_tool "$src" "$pkg"; then TOOLS_OK+=("$pkg"); else TOOLS_KO+=("$pkg"); fi
done
echo "  built: ${TOOLS_OK[*]:-none}"
[ ${#TOOLS_KO[@]} -gt 0 ] && warn "failed to build: ${TOOLS_KO[*]}"
rm -rf /tmp/omabuild
fi
# Omarchy deliberately replaces two Yaru icons with Adwaita's; if Yaru
# was just installed, it needs to be reapplied.
sudo bash "$OMARCHY_PATH/install/config/theme-system.sh" >/dev/null 2>&1 || true

# herdr is left out: its PKGBUILD uses `zig fetch` with Zig 0.15 semantics, and
# Arch Linux ARM only packages 0.16 ("no build.zig file found"). Building
# zig0.15 from source takes hours, and it's a development tool, not a
# desktop one.

# --- the kernel reboot notice, which never turns off on ARM -------
# omarchy-update-restart decides whether the kernel changed by looking for a vmlinuz inside
# /usr/lib/modules/<version>/ that belongs to a package. On Arch x86_64 the
# linux package installs it there; on Arch Linux ARM, linux-aarch64 leaves the image
# at /boot/Image and does NOT create that vmlinuz. The loop finds nothing, the variable
# stays "true" and asks for a reboot on every update, forever.
# This wrapper compares what actually matters: uname -r against the module
# directory owned by the kernel package. /usr/local/bin comes before
# /usr/bin in the PATH, so it replaces the original without touching the tree.
log "omarchy-update-restart wrapper (kernel notice on ALARM)"
sudo install -Dm755 /dev/stdin /usr/local/bin/omarchy-update-restart <<'KRN'
#!/bin/bash
# On Arch Linux ARM the kernel doesn't leave a vmlinuz in /usr/lib/modules/<ver>/, which is
# what the original looks for: without it, it always asks for a reboot. uname -r is compared
# against the module directory that belongs to the kernel package.
if [ -z "${OMARCHY_SKIP_KERNEL_CHECK:-}" ]; then
  # modules.dep is generated by depmod and doesn't belong to any package. modules.builtin
  # IS shipped by linux-aarch64, so it can tell whether the module directory
  # of the running kernel is the one from the installed package.
  pkg=$(pacman -Qoq /usr/lib/modules/"$(uname -r)"/modules.builtin 2>/dev/null \
        || pacman -Qoq /usr/lib/modules/"$(uname -r)"/modules.order 2>/dev/null || true)
  if [ -n "$pkg" ]; then
    # The module directory of the running kernel belongs to the
    # installed package: there's no new kernel waiting for a reboot.
    export OMARCHY_KERNEL_CURRENT=1
  fi
fi
REAL=/usr/bin/omarchy-update-restart
[ -x "$REAL" ] || exit 0
if [ -n "${OMARCHY_KERNEL_CURRENT:-}" ]; then
  # Only the kernel block is skipped; the rest (Hyprland, services, shell)
  # is left intact by running the original with that check already resolved.
  sed 's#^kernel_updated=true$#kernel_updated=false#' "$REAL" | bash -s -- "$@"
else
  exec "$REAL" "$@"
fi
KRN
echo "  /usr/local/bin/omarchy-update-restart"

# --- ttfx: screensaver text effects (Rust, ~12 min) -----------
if ! command -v ttfx >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
  log "building ttfx from source (doesn't exist for aarch64)"
  rm -rf /tmp/ttfx-src
  # The build path ends up INSIDE the binary: Rust embeds the source path
  # in panic messages (.rodata), and strip doesn't reach there. If it's
  # built from $HOME, the distributed image ends up revealing who
  # built it. It's built in /tmp, with CARGO_HOME in /tmp so the dependency
  # paths don't go through the home directory either, and with --remap-path-prefix in case
  # one slips through anyway.
  if git clone --depth 1 -q https://github.com/omacom-io/ttfx.git /tmp/ttfx-src \
     && ( cd /tmp/ttfx-src \
          && CARGO_HOME=/tmp/cargo-ttfx \
             RUSTFLAGS="--remap-path-prefix=/tmp/ttfx-src=ttfx --remap-path-prefix=/tmp/cargo-ttfx=cargo --remap-path-prefix=$HOME=." \
             cargo build --release -q ); then
    sudo install -Dm755 /tmp/ttfx-src/target/release/ttfx /usr/local/bin/ttfx
    echo "  ttfx $(ttfx --version 2>/dev/null | head -1)"
  else
    warn "ttfx failed to build; the screensaver will show the logo without effects"
  fi
  rm -rf /tmp/ttfx-src /tmp/cargo-ttfx
fi

# --- keyboard: es layout and a usable Super key from macOS -------------------
# macOS intercepts Cmd before UTM ever sees it (Cmd+Space opens Spotlight), so
# Omarchy's SUPER shortcuts would be unreachable. altwin:swap_lalt_lwin
# swaps Alt and Super: the Mac's Option (⌥) key acts as SUPER.
cat > ~/.config/hypr/input.lua <<LUA
hl.config({
  input = {
    kb_layout  = "$VM_XKB",
    kb_options = "compose:caps,shift:both_capslock_cancel,altwin:swap_lalt_lwin",
  },
})
LUA

# --- no blur: rendering goes through llvmpipe (see 90-vm-graphics.conf) --------
cat > ~/.config/hypr/looknfeel.lua <<'LUA'
hl.config({
  decoration = {
    blur   = { enabled = false },
    shadow = { enabled = false },
  },
})
LUA

# --- environment reinforcement for apps launched by uwsm --------------------
mkdir -p ~/.config/uwsm/env.d
cat > ~/.config/uwsm/env.d/20-vm-graphics <<'ENVEOF'
export LIBGL_ALWAYS_SOFTWARE=1
ENVEOF

# User directories
xdg-user-dirs-update 2>/dev/null || true
mkdir -p ~/Pictures/Screenshots ~/Videos ~/Desktop ~/Documents ~/Downloads

# ------------------------------------------------------------ git
# --- optional installer for apps not included in the image ---------------
# Several apps (1Password, Obsidian, Typora, LocalSend) DO have an official
# arm64 build, but they're proprietary: including them in an image that gets distributed
# would mean redistributing third-party binaries. The installer is left manual instead.
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-extras" ]; then
  log "optional app installer (omarchy-arm-extras)"
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-extras" /usr/local/bin/omarchy-arm-extras
  sudo install -Dm644 /dev/stdin /usr/local/share/applications/omarchy-arm-extras.desktop <<'DESK'
[Desktop Entry]
Name=Install missing apps (ARM)
Comment=1Password, Obsidian, Typora, LocalSend, Google Chrome
Exec=xdg-terminal-exec omarchy-arm-extras
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;PackageManager;
DESK
  echo "  available as a command and in the application menu"
fi

# --- clipboard shared with the host ---------------------------
# The SPICE clipboard goes through three hops:
#   SPICE client (UTM) <-virtio-> spice-vdagentd <-unix socket-> agent
# The daemon talks to the host; the session agent only talks to the
# daemon. The OFFICIAL agent hands the clipboard to X11 (vdagent.c:421 ->
# vdagent_clipboards_new(vdagent_display_get_x11(...)), zero references to
# wlr-data-control) and under Hyprland it dies with "cannot open display".
#
# omarchy-arm-vdagent fills that gap: same udscs protocol with the daemon,
# but wl-copy/wl-paste on the other side. The daemon stays as-is (with -X,
# see stage2): we're replacing the agent, NOT the daemon. Trying to talk over the
# virtio port directly leaves the daemon without a channel ("Device or resource
# busy") and the host ignores everything.
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-vdagent" ]; then
  log "clipboard agent for Wayland"
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-vdagent" /usr/local/bin/omarchy-arm-vdagent
  # The official agent must not start: vdagentd disconnects both if it sees
  # two agents in the same session ("multiple agents in one session").
  sudo systemctl --global mask spice-vdagent.service 2>/dev/null || true
  mkdir -p ~/.config/systemd/user
  cat > ~/.config/systemd/user/omarchy-arm-vdagent.service <<'UNIT'
[Unit]
Description=Clipboard shared with the host (SPICE over Wayland)
After=graphical-session.target
PartOf=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY

[Service]
Type=simple
# The socket is created by spice-vdagentd at startup; if it's not there yet, retry.
ExecStartPre=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do [ -S /run/spice-vdagentd/spice-vdagent-sock ] && exit 0; sleep 2; done; exit 1'
ExecStart=/usr/local/bin/omarchy-arm-vdagent
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable omarchy-arm-vdagent.service 2>/dev/null || true
  echo "  /usr/local/bin/omarchy-arm-vdagent + user service"
fi
# Bridge via shared folder, as a fallback if the SPICE channel isn't
# available (for example with Apple's virtualization backend).
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-clipboard" ]; then
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-clipboard" /usr/local/bin/omarchy-arm-clipboard
  echo "  /usr/local/bin/omarchy-arm-clipboard (fallback via shared folder)"
fi
if [ -f "$HOME/.omarchy-arm-prov/omarchy-arm-share" ]; then
  sudo install -Dm755 "$HOME/.omarchy-arm-prov/omarchy-arm-share" /usr/local/bin/omarchy-arm-share
  echo "  /usr/local/bin/omarchy-arm-share (mounts the folder, whether VirtFS or WebDAV)"

  # OBS Studio and Pinta are free software: they can ship inside the image, and
  # that's how it's distributed. They're installed with the same installer to avoid
  # duplicating its logic (OBS needs the browser plugin removed, whose CEF is
  # x86-only; Pinta needs Microsoft's arm64 .NET, which Arch doesn't package).
  # It's the most expensive part of the build: ~45 min. WANT_EXTRAS=no skips it.
  if [ "${WANT_EXTRAS:-yes}" = "yes" ]; then
    log "OBS Studio and Pinta (free software, ship inside the image; ~45 min)"
    if /usr/local/bin/omarchy-arm-extras pinta obs; then
      echo "  pinta: $(pacman -Q pinta 2>/dev/null || echo MISSING)"
      echo "  obs:   $(pacman -Q obs-studio 2>/dev/null || echo MISSING)"
    else
      warn "OBS or Pinta didn't install; they can be added later with:"
      warn "  omarchy-arm-extras pinta obs"
    fi
  else
    echo "  OBS and Pinta skipped (WANT_EXTRAS=no)"
  fi
fi

# --- updates: making "Update System" work and be reversible --------
# a) snapper: without it, omarchy-snapshot returns 127 and every update happens
#    without a prior snapshot, i.e. with no way to roll back.
# b) post-update hook: omarchy-update-dev only does a `git pull` when
#    OMARCHY_PATH points OUTSIDE /usr/share/omarchy, and here it points exactly there.
#    Without the hook, the system receives packages but the Omarchy tree (scripts,
#    themes, config) stays frozen at the cloned version.
log "updates: snapper + post-update hook"
sudo pacman -S --noconfirm --needed --disable-download-timeout snapper >/dev/null 2>&1 || warn "snapper not available"
if command -v snapper >/dev/null 2>&1; then
  sudo bash -euo pipefail "$OMARCHY_PATH/install/config/snapper.sh" >/dev/null 2>&1 \
    && echo "  snapper configured: snapshot before every update" \
    || warn "couldn't configure snapper"
fi
if [ -f "$HOME/.omarchy-arm-prov/10-arm-sync" ]; then
  install -Dm755 "$HOME/.omarchy-arm-prov/10-arm-sync" ~/.config/omarchy/hooks/post-update.d/10-arm-sync
  echo "  post-update hook installed"
fi

log "git"
git config --global user.name  "$VM_FULLNAME"
git config --global user.email "$VM_EMAIL"
git config --global init.defaultBranch master

# ------------------------------------------------------------ summary
log "summary"
echo "  omarchy:   $(ls -d "$OMARCHY_PATH" 2>/dev/null || echo MISSING)"
echo "  ~/.config: $(ls ~/.config | wc -l) entries"
echo "  theme:     $(readlink -f ~/.config/omarchy/current/theme 2>/dev/null || echo 'not linked')"
echo "  hyprland:  $(command -v Hyprland || command -v hyprland || echo 'NO')"
echo "  omarchy-shell: $(command -v omarchy-shell || echo 'NO')"
echo "  terminal:  $(command -v xdg-terminal-exec || echo 'NO')"
echo ""
echo "==> [stage3] COMPLETED"
__PAYLOAD_PROVISION_STAGE3_SH__
chmod +x "$W/provision/stage3.sh"

mkdir -p "$W/provision"
cat > "$W/provision/repair.sh" <<'__PAYLOAD_PROVISION_REPAIR_SH__'
#!/bin/sh
# Reopens the already-installed system on /dev/vda and runs a script inside the
# chroot, without repartitioning or downloading anything. For iterating after a
# one-off failure.
set -eu
PROV=/media/prov
log() { echo ""; echo "==> [repair] $*"; }
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "TOK_REPAIR_$rc"' EXIT

log "kernel modules"
# Mounting btrfs/vfat only needs the kernel module, not the userspace
# utilities: this stage does NOT depend on network access.
for m in btrfs vfat fat nls_cp437 nls_iso8859-1 nls_utf8 crc32c-generic xxhash_generic; do
  modprobe "$m" 2>/dev/null || true
done
grep -qw btrfs /proc/filesystems || { echo "!! the live kernel does not support btrfs"; exit 1; }
echo "  filesystems: $(tr '\n' ' ' < /proc/filesystems | tr -s ' ')"

log "network (best-effort, convenience only)"
ip link set eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -t 8 >/dev/null 2>&1 || true
ip -4 addr show eth0 2>/dev/null | grep -o 'inet [0-9.]*' || echo "  (no network; continuing anyway)"

log "mounting the installed system"
umount -R /mnt 2>/dev/null || true
if mount -t btrfs -o rw,noatime,compress=zstd:3,subvol=@ /dev/vda2 /mnt 2>/dev/null; then
  mount -t btrfs -o rw,noatime,compress=zstd:3,subvol=@home /dev/vda2 /mnt/home
else
  mount -t ext4 /dev/vda2 /mnt
fi
mount -t vfat /dev/vda1 /mnt/boot
for d in proc sys dev run tmp; do mkdir -p "/mnt/$d"; done
mount -t proc none /mnt/proc
mount -t sysfs none /mnt/sys
mount --rbind /dev /mnt/dev
mount --make-rslave /mnt/dev
mount -t tmpfs none /mnt/run
mount -t tmpfs -o size=4G none /mnt/tmp
mkdir -p /mnt/dev/pts && mount -t devpts none /mnt/dev/pts 2>/dev/null || true
rm -f /mnt/etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /mnt/etc/resolv.conf
df -h /mnt /mnt/boot

log "running $FIXSCRIPT inside the chroot"
mkdir -p /mnt/root/prov
cp "$PROV/$FIXSCRIPT" /mnt/root/prov/
[ -f "$PROV/config.env" ] && cp "$PROV/config.env" /mnt/root/prov/
[ -f "$PROV/extras.sh" ] && cp "$PROV/extras.sh" /mnt/root/prov/omarchy-arm-extras
[ -f "$PROV/armsync.sh" ] && cp "$PROV/armsync.sh" /mnt/root/prov/10-arm-sync
[ -f "$PROV/clipbrd.sh" ] && cp "$PROV/clipbrd.sh" /mnt/root/prov/omarchy-arm-clipboard
[ -f "$PROV/vdagent.py" ] && cp "$PROV/vdagent.py" /mnt/root/prov/omarchy-arm-vdagent
[ -f "$PROV/share.sh" ] && cp "$PROV/share.sh" /mnt/root/prov/omarchy-arm-share
[ -f "$PROV/fsinfo.env" ] && cp "$PROV/fsinfo.env" /mnt/root/prov/
[ -f "$PROV/stage3.sh" ] && cp "$PROV/stage3.sh" /mnt/root/prov/
[ -f "$PROV/packages-core.txt" ] && cp "$PROV/packages-core.txt" /mnt/root/prov/
[ -f "$PROV/packages-extra.txt" ] && cp "$PROV/packages-extra.txt" /mnt/root/prov/
chmod +x /mnt/root/prov/*.sh
set +e
chroot /mnt /bin/bash "/root/prov/$FIXSCRIPT"
rc=$?
set -e

# The working directory must not stay inside the system: it would accumulate
# every repair script from every pass.
log "removing /root/prov from the installed system"
ls /mnt/root/prov 2>/dev/null | tr '\n' ' '; echo
rm -rf /mnt/root/prov

log "unmounting"
sync
umount -R /mnt/tmp /mnt/run /mnt/dev /mnt/sys /mnt/proc 2>/dev/null || true
umount -R /mnt/boot 2>/dev/null || true
umount -R /mnt 2>/dev/null || umount -l /mnt
sync
echo "TOK_REPAIR_$rc"
trap - EXIT
exit $rc
__PAYLOAD_PROVISION_REPAIR_SH__
chmod +x "$W/provision/repair.sh"

mkdir -p "$W/provision"
cat > "$W/provision/sanitize.sh" <<'__PAYLOAD_PROVISION_SANITIZE_SH__'
#!/bin/bash
# Sanitize for distribution: strips everything that identifies the system and
# leaves a generic user. Runs as ROOT inside the chroot.
set -uo pipefail
# config.env is dropped by stage1 inside the guest: it's the only channel the
# host has to communicate the build user. Without this, changing
# VM_USER would make sanitize try to rename a user that doesn't exist.
[ -f /root/prov/config.env ] && . /root/prov/config.env
OLD="${DIST_OLD_USER:-${VM_USER:-}}"
NEW="${DIST_NEW_USER:-omarchy}"
[ -n "$OLD" ] || { echo "sanitize: don't know which user to start from" >&2; exit 1; }
getent passwd "$OLD" >/dev/null || { echo "sanitize: user '$OLD' does not exist" >&2; exit 1; }
log()  { echo ""; echo "==> $*"; }
warn() { echo "!!  $*" >&2; }

log "1/10 unpinning /usr/share/omarchy from the user's home"
# It was a symlink to /home/<user>/.local/share/omarchy, which ties the system
# to that user. It's converted into a real directory (as the pacman package
# would) and the home then points there instead.
if [ -L /usr/share/omarchy ]; then
  TARGET=$(readlink -f /usr/share/omarchy)
  rm -f /usr/share/omarchy
  # Without set -e, a partial cp (typically from a full disk: we just
  # duplicated the whole tree) didn't stop the rm -rf below. The original got
  # deleted and /usr/share/omarchy was left incomplete: a desktop with no
  # themes and no commands, with the phase reporting OK. Now the original is
  # only deleted once the copy is confirmed complete.
  # The rollback has to leave the system EXACTLY as it was, or the next
  # attempt finds /usr/share/omarchy already converted into a half-finished
  # directory, skips this whole block (the guard is [ -L ... ]), and passes
  # the image as good. That's why the partial copy is removed before
  # recreating the symlink: 'ln -sfn' on a real directory creates the link
  # INSIDE it.
  roll_back() {
    warn "$1"
    rm -rf /usr/share/omarchy
    ln -sfn "$TARGET" /usr/share/omarchy
    exit 1
  }
  cp -a "$TARGET" /usr/share/omarchy \
    || roll_back "couldn't copy $TARGET to /usr/share/omarchy"
  chown -R root:root /usr/share/omarchy
  N_ORIG=$(find "$TARGET" -mindepth 1 | wc -l)
  N_COPIA=$(find /usr/share/omarchy -mindepth 1 | wc -l)
  [ "$N_COPIA" -ge "$N_ORIG" ] \
    || roll_back "the copy is incomplete ($N_COPIA of $N_ORIG entries)"
  rm -rf "$TARGET"
  echo "  /usr/share/omarchy is now a real directory ($(du -sh /usr/share/omarchy | cut -f1), $N_COPIA entries)"
fi

log "2/10 renaming user $OLD -> $NEW"
if id -u "$OLD" >/dev/null 2>&1; then
  pkill -u "$OLD" 2>/dev/null || true
  usermod -l "$NEW" -d "/home/$NEW" -m "$OLD"
  groupmod -n "$NEW" "$OLD" 2>/dev/null || true
  echo "$NEW:$NEW" | chpasswd
  echo "root:$NEW"  | chpasswd
fi
id "$NEW"
# the user's home points into the system tree
install -d -o "$NEW" -g "$NEW" "/home/$NEW/.local/share"
rm -rf "/home/$NEW/.local/share/omarchy"
ln -sfn /usr/share/omarchy "/home/$NEW/.local/share/omarchy"
chown -h "$NEW:$NEW" "/home/$NEW/.local/share/omarchy"

log "3/10 SDDM: autologin to the generic user"
cat > /etc/sddm.conf.d/20-autologin.conf <<EOF
[Autologin]
User=$NEW
Session=omarchy
EOF
grep -rl "$OLD" /etc/sddm.conf.d/ 2>/dev/null | while read -r f; do sed -i "s/\b$OLD\b/$NEW/g" "$f"; done
cat /etc/sddm.conf.d/20-autologin.conf

log "4/10 credentials and keys"
rm -rf "/home/$NEW/.ssh"
rm -f /etc/ssh/ssh_host_*        # regenerated automatically on first boot
systemctl disable sshd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/sshd.service
rm -f /etc/sudoers.d/99-fix /etc/sudoers.d/99-install
rm -rf "/home/$NEW/.gnupg" "/home/$NEW/.local/share/keyrings" "/home/$NEW/.password-store"
echo "  sshd: $(systemctl is-enabled sshd 2>&1)"

log "5/10 machine identity"
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/hostname; echo omarchy > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   omarchy.localdomain omarchy
EOF

log "6/10 personal identity (git, histories, cache)"
rm -f "/home/$NEW/.gitconfig" "/home/$NEW/.config/git/config"
rm -f "/home/$NEW/.bash_history" "/home/$NEW/.zsh_history" "/home/$NEW/.local/share/fish/fish_history"
rm -rf "/home/$NEW/.cache" "/home/$NEW/.local/state/omarchy/first-run.log"
rm -rf "/home/$NEW/.local/share/omarchy-"* 2>/dev/null || true
rm -rf "/home/$NEW/shots" "/home/$NEW"/*.sh "/home/$NEW/config.env" 2>/dev/null || true
# NetworkManager: remove saved wifi networks
rm -f /etc/NetworkManager/system-connections/* 2>/dev/null || true

log "7b/10 proprietary apps out of the distributable image"
# These are installed with omarchy-arm-extras on the end user's machine.
# Bundling them into a .zip that gets distributed would mean redistributing
# third-party binaries, so they're removed even if they were present in the
# source VM.
for pkg in 1password 1password-cli typora localsend-bin google-chrome obsidian-bin; do
  pacman -Q "$pkg" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$pkg" >/dev/null 2>&1 && echo "  removed $pkg"; }
done
for d in /opt/1Password /opt/obsidian /opt/typora; do
  [ -e "$d" ] && { rm -rf "$d"; echo "  removed $d"; }
done
rm -f /usr/local/bin/obsidian /usr/local/share/applications/obsidian.desktop 2>/dev/null || true
# Removing /opt/1Password leaves its /usr/bin symlinks pointing at nothing.
# It's the same old oversight: a text sweep can't see where a symlink points.
for l in $(find /usr/bin /usr/local/bin -maxdepth 1 -xtype l 2>/dev/null); do
  case "$(readlink "$l")" in
    /opt/1Password/*|/opt/obsidian/*|/opt/typora/*)
      rm -f "$l"; echo "  removed dangling symlink: $l" ;;
  esac
done
# Traces left behind by their install: if Chrome is removed, the Spotify
# webapp shortcut and launcher that invoke it need removing too. Otherwise
# the image ships with a SUPER+SHIFT+M that points at a nonexistent binary.
BIND="/home/$NEW/.config/hypr/bindings.lua"
if [ -f "$BIND" ] && grep -q "open.spotify.com" "$BIND"; then
  sed -i '/^-- Spotify no tiene cliente nativo/,/^o.bind("SUPER + SHIFT + M", "Spotify"/d' "$BIND"
  sed -i '/open\.spotify\.com/d' "$BIND"
  echo "  removed the SUPER+SHIFT+M shortcut for the Spotify webapp"
fi
rm -f "/home/$NEW/.local/share/applications/Spotify.desktop" \
      "/home/$NEW/.local/share/applications/spotify.desktop" 2>/dev/null || true
rm -rf "/home/$NEW/.local/share/omarchy/webapps" 2>/dev/null || true
echo "  (reinstall with: omarchy-arm-extras)"

log "7c/10 slimming down: what was only needed to compile"
# Compiling the tools leaves entire toolchains behind (the .NET SDK alone is
# 425 MiB), plus Rust and Go toolchains in the home. None of that is needed to
# use the image, and it accounts for ~2 GB of the zip.
for p in dotnet-sdk-bin dotnet-targeting-pack-bin aspnet-targeting-pack-bin; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  removed $p"; }
done
# Omarchy 4 retires these four: quickshell is now the bar, the menu, the OSD,
# and the notification daemon. mako also grabs org.freedesktop.Notifications
# via D-Bus activation and leaves notifications without a theme. They
# shouldn't be installed, but if a future version of the list reintroduces
# them, they're out.
for p in mako swayosd walker elephant; do
  pacman -Q "$p" >/dev/null 2>&1 && { pacman -Rns --noconfirm "$p" >/dev/null 2>&1 && echo "  retired $p"; }
done
rm -rf "/home/$NEW/.config/mako" "/home/$NEW/.config/walker" "/home/$NEW/.config/swayosd"
rm -f  /usr/local/bin/walker
orph=$(pacman -Qdtq 2>/dev/null | tr '\n' ' ')
[ -n "${orph// /}" ] && { echo "  orphans: $orph"; pacman -Rns --noconfirm $orph >/dev/null 2>&1; }
rm -rf "/home/$NEW/.cargo" "/home/$NEW/go" "/home/$NEW/.rustup" "/home/$NEW/.npm" 2>/dev/null
echo "  essentials that must remain: $(for p in hyprland quickshell sddm; do printf '%s ' "$(pacman -Q $p 2>/dev/null || echo MISSING-$p)"; done)"

log "7d/10 slimming down: what can't possibly be needed in a VM"
# Measured on a real image: 675 MiB of firmware for hardware that can't exist
# in a QEMU VM with virtio devices. linux-firmware isn't installed on
# purpose, but the per-vendor splits come in as dependencies.
FW=$(pacman -Qq 2>/dev/null | grep -E '^linux-firmware-(intel|nvidia|amdgpu|atheros|broadcom|realtek|mediatek|marvell|qcom|qlogic|liquidio|bnx2x|mellanox|nfp|other)$' | tr '\n' ' ')
if [ -n "${FW// /}" ]; then
  echo "  firmware for absent hardware: $FW"
  # -Rdd: the splits are claimed by the linux-firmware metapackage, which also
  # isn't needed. If anything objects, it's left as-is and nothing breaks.
  pacman -Rdd --noconfirm $FW linux-firmware >/dev/null 2>&1 \
    && echo "  removed" || echo "  (couldn't be removed; left in place)"
fi
# Documentation and manpages: 469 MiB. This is an image for trying out a
# desktop, not a server where you'd read man pages. Omarchy's .md files are
# NOT touched.
for d in /usr/share/doc /usr/share/man /usr/share/info /usr/share/gtk-doc; do
  [ -d "$d" ] && { echo "  $d: $(du -shx "$d" 2>/dev/null | cut -f1)"; rm -rf "$d"; }
done
mkdir -p /usr/share/man /usr/share/doc
echo "  usage after the trim: $(df -h / | awk 'NR==2{print $3}')"

log "7/10 system logs and caches"
rm -rf /var/log/journal/* /var/log/omarchy* /var/log/pacman.log
find /var/log -type f -name "*.log" -delete 2>/dev/null || true
rm -rf /var/cache/pacman/pkg/* /var/tmp/* /tmp/* 2>/dev/null || true
# NOTE: /root/prov is NOT deleted here. Steps 8a and 8b read the update hook
# and the optional-apps installer from there; deleting it earlier left the
# image without either one, silently. repair.sh removes it on exiting the
# chroot, which is where it belongs.
rm -rf /root/.bash_history /root/.cache 2>/dev/null || true
rm -f /root/STAGE2_OK 2>/dev/null || true
# stage2 writes this when some package fails to install. In an image that
# gets distributed, it tells the recipient what failed for the builder.
rm -f /root/failed-packages.txt 2>/dev/null || true
# The verify phase boots the VM before sanitizing, and that boot leaves
# behind a random seed and a credential secret: identical across every copy.
rm -f /var/lib/systemd/random-seed /var/lib/systemd/credential.secret 2>/dev/null || true
: > /var/log/wtmp 2>/dev/null || true
: > /var/log/btmp 2>/dev/null || true
: > /var/log/lastlog 2>/dev/null || true

log "8/10 notice for the recipient"
cat > /etc/motd <<'EOF'

  Omarchy on Arch Linux ARM (aarch64) — image for UTM on Apple Silicon

  User: omarchy   Password: omarchy   (also for root)

  >> CHANGE THE PASSWORD NOW:  passwd

  Keys: the Mac's Option key (⌥) acts as SUPER.
        ⌥+Space  Omarchy menu      ⌥+Return  terminal

  Missing 1Password, Obsidian, Typora, Spotify, or LocalSend?
  They're not bundled in for licensing reasons, but all have an official ARM64 build:

      omarchy-arm-extras --list     see what it can install
      omarchy-arm-extras            interactive menu

EOF
install -d -o "$NEW" -g "$NEW" "/home/$NEW/Desktop"
cp /etc/motd "/home/$NEW/Desktop/README.txt"
chown "$NEW:$NEW" "/home/$NEW/Desktop/README.txt"

log "8a/10 update hook for ARM"
# omarchy-update-dev doesn't update the tree when OMARCHY_PATH is
# /usr/share/omarchy, which is our case: without this hook, Omarchy freezes.
if [ -f /root/prov/10-arm-sync ]; then
  install -Dm755 /root/prov/10-arm-sync "/home/$NEW/.config/omarchy/hooks/post-update.d/10-arm-sync"
  chown -R "$NEW:$NEW" "/home/$NEW/.config/omarchy/hooks" 2>/dev/null || true
  echo "  post-update.d/10-arm-sync"
fi
# The checkout must not get dirtied by permission changes, or the pull will fail
git -C /usr/share/omarchy config core.fileMode false 2>/dev/null || true
git -C /usr/share/omarchy checkout -- . 2>/dev/null || true
echo "  clean checkout: $(git -C /usr/share/omarchy status --porcelain 2>/dev/null | wc -l) files"

log "8b/10 optional apps installer"
# repair.sh copies extras.sh as omarchy-arm-extras, but if that copy didn't
# happen, this whole block used to skip silently and the image shipped
# without the menu entry. Both names are accepted, and a warning fires if
# neither is found.
EXTRAS_SRC=""
for c in /root/prov/omarchy-arm-extras /root/prov/extras.sh; do
  [ -f "$c" ] && { EXTRAS_SRC="$c"; break; }
done
if [ -n "$EXTRAS_SRC" ]; then
  install -Dm755 "$EXTRAS_SRC" /usr/local/bin/omarchy-arm-extras
  install -Dm644 /dev/stdin /usr/local/share/applications/omarchy-arm-extras.desktop <<'DESK'
[Desktop Entry]
Name=Install missing apps (ARM)
Comment=1Password, Obsidian, Typora, LocalSend, Chrome, OBS, Pinta
Exec=xdg-terminal-exec omarchy-arm-extras
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;PackageManager;
DESK
  chown "$NEW:$NEW" /usr/local/share/applications/omarchy-arm-extras.desktop 2>/dev/null || true
  echo "  /usr/local/bin/omarchy-arm-extras + menu entry"
else
  warn "the optional apps installer wasn't on the ISO: the image will ship without it"
fi

log "9/10 checking that nothing is still tied to $OLD"
echo "  references in /etc:"; grep -rl "\b$OLD\b" /etc 2>/dev/null | head -5 || echo "    none"
echo "  home:"; ls -ld "/home/$NEW"; ls /home/
echo "  owner of stray files:"; find /home/$NEW -maxdepth 2 ! -user "$NEW" 2>/dev/null | head -3 || echo "    all correct"

log "10/10 freeing unused space (so it compresses better)"
sync
fstrim -av 2>&1 | head -3 || true
echo ""
log "usermod backup files (contain the old user and password hash)"
rm -f /etc/passwd- /etc/shadow- /etc/group- /etc/gshadow-
log "subuid/subgid"
sed -i "s/^$OLD:/$NEW:/" /etc/subuid /etc/subgid 2>/dev/null || true
cat /etc/subuid /etc/subgid 2>/dev/null

log "final sweep for references to $OLD"
echo "  /etc:"; grep -rl "\b$OLD\b" /etc 2>/dev/null || echo "    none"
echo "  /home:"; grep -rl "\b$OLD\b" /home/$NEW/.config /home/$NEW/.bashrc 2>/dev/null | head -5 || echo "    none"
echo "  /usr/local/bin:"; grep -rl "\b$OLD\b" /usr/local/bin 2>/dev/null | head -5 || echo "    none"
echo "  broken symlinks in /usr/bin: $(find /usr/bin -xtype l 2>/dev/null | wc -l)"
echo "  /usr/share/omarchy (must not point into /home):"; ls -ld /usr/share/omarchy

log "system consistency"
echo "  passwd: $(getent passwd $NEW)"
echo "  home:   $(ls -ld /home/$NEW | awk '{print $3, $4, $9}')"
echo "  symlink omarchy: $(readlink /home/$NEW/.local/share/omarchy)"
echo "  autologin: $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | tr '\n' ' ')"
echo "  omarchy binaries: $(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l) in /usr/bin"
echo "  ttfx: $(command -v ttfx || echo NO)"
echo "  sealed migrations: $(ls -1 /home/$NEW/.local/state/omarchy/migrations 2>/dev/null | wc -l)"
sync
echo ""
log "Nautilus/GTK bookmarks pointing at the old home"
for f in /home/$NEW/.config/gtk-3.0/bookmarks /home/$NEW/.config/gtk-4.0/bookmarks; do
  [ -f "$f" ] && { sed -i "s#/home/$OLD#/home/$NEW#g" "$f"; echo "  $f:"; cat "$f"; }
done

log "real name in passwd (shown in the greeter)"
chfn -f "Omarchy" "$NEW" 2>/dev/null || usermod -c "Omarchy" "$NEW"
getent passwd "$NEW"

log "user-dirs with absolute paths"
for f in /home/$NEW/.config/user-dirs.dirs; do
  [ -f "$f" ] && sed -i "s#/home/$OLD#/home/$NEW#g" "$f"
done

log "symlinks pointing at the old home"
# grep -rl only looks at file CONTENTS: a symlink's target isn't content, so
# the text sweep marks them clean. Omarchy stores the active theme and
# background as symlinks
# (~/.local/state/omarchy/current/{theme,background}), so a dangling link
# leaves the desktop gray and unstyled, with no visible error.
mapfile -t BADLINKS < <(find /home/$NEW /etc /usr/bin /usr/local /opt -xdev -type l \
  -lname "*/home/$OLD/*" 2>/dev/null)
echo "  found: ${#BADLINKS[@]}"
for l in "${BADLINKS[@]:-}"; do
  [ -n "$l" ] || continue
  tgt=$(readlink "$l")
  ln -sfn "${tgt//\/home\/$OLD\//\/home\/$NEW\/}" "$l"
  echo "  $l -> $(readlink "$l")"
done
chown -h $NEW:$NEW "${BADLINKS[@]:-/home/$NEW}" 2>/dev/null || true

log "final sweep"
echo "  /etc:   $(grep -rl "\b$OLD\b" /etc 2>/dev/null | wc -l) matches"
echo "  /home:  $(grep -rl "\b$OLD\b" /home/$NEW/.config /home/$NEW/.bashrc /home/$NEW/.bash_profile 2>/dev/null | wc -l) matches"
echo "  symlinks to /home/$OLD: $(find /home/$NEW /etc /usr/bin /usr/local /opt -xdev -type l -lname "*/home/$OLD/*" 2>/dev/null | wc -l)"
echo "  broken symlinks in the home: $(find /home/$NEW -xdev -type l ! -exec test -e {} \; -print 2>/dev/null | wc -l)"
echo "  broken symlinks in /usr/bin: $(find /usr/bin -xtype l 2>/dev/null | wc -l)"
echo "  active background: $(readlink -f /home/$NEW/.local/state/omarchy/current/background 2>/dev/null || echo NONE)"
test -e "/home/$NEW/.local/state/omarchy/current/background" \
  && echo "  background resolves: OK" || echo "  background resolves: BROKEN"
# ttfx is compiled from source inside the VM, and the binary keeps the build
# path in its debug info: /home/<builder>/... That's exactly what this phase
# exists to erase, so its symbols get stripped instead of declaring it
# harmless, which is what this used to do.
for b in /usr/local/bin/ttfx /usr/local/bin/omarchy-arm-vdagent; do
  [ -f "$b" ] || continue
  case "$(file -b "$b" 2>/dev/null)" in
    *ELF*) strip --strip-unneeded "$b" 2>/dev/null || true ;;
  esac
done
if strings /usr/local/bin/ttfx 2>/dev/null | grep -q "$OLD"; then
  echo "  ttfx: STILL mentions '$OLD' after the strip"
else
  echo "  ttfx: no trace of the builder"
fi

log "final state for distribution"
echo "  user:       $(getent passwd $NEW | cut -d: -f1,5,6)"
echo "  autologin:  $(grep -h User= /etc/sddm.conf.d/*.conf 2>/dev/null | sort -u | tr '\n' ' ')"
echo "  sshd:       $(systemctl is-enabled sshd 2>&1)"
echo "  optional installer: $(test -x /usr/local/bin/omarchy-arm-extras && echo yes || echo MISSING)"
echo "  menu entry:          $(test -f /usr/local/share/applications/omarchy-arm-extras.desktop && echo yes || echo MISSING)"
echo "  machine-id: $(wc -c < /etc/machine-id) bytes (empty = will regenerate)"
echo ""
echo "  WARNING: from this point on, the image must not be booted again. The first"
echo "  boot regenerates machine-id, the random seed, and logs, and those would"
echo "  end up identical across every distributed copy. If you need to boot it"
echo "  to verify something, re-run this phase afterward."
echo "  ssh host keys: $(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l) (0 = will regenerate)"
echo "  hostname:   $(cat /etc/hostname)"
sync
fstrim -av 2>&1 | head -2 || true

# ─────────────────────── invariants: this CAN fail ──────────────────────────
# Up to here everything was `echo`: the script runs without -e and always
# ended on an echo, so its rc was 0 no matter what happened. repair.sh picked
# up that 0, the host saw TOK_REPAIR_0, and declared the image clean. If
# usermod failed, an image shipped with the builder's user and password.
log "invariants of the distributable image"
FAILURES=0
fail_check() { echo "  ✗ $*"; FAILURES=$((FAILURES+1)); }
pass_check() { echo "  ✓ $*"; }

getent passwd "$NEW" >/dev/null && pass_check "user $NEW exists" || fail_check "user $NEW does not exist"
if [ "$OLD" != "$NEW" ]; then
  getent passwd "$OLD" >/dev/null && fail_check "the builder's user ($OLD) still exists" \
                                  || pass_check "the builder's user no longer exists"
fi
[ -d /usr/share/omarchy ] && [ ! -L /usr/share/omarchy ] \
  && pass_check "/usr/share/omarchy is a real directory" \
  || fail_check "/usr/share/omarchy is not a real directory"

N_CMD=$(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l)
[ "$N_CMD" -ge 400 ] && pass_check "$N_CMD omarchy-* commands" || fail_check "only $N_CMD omarchy-* commands (expected >=400)"

N_ROTO=$(find /usr/bin /usr/local/bin /home/"$NEW" -xdev -xtype l 2>/dev/null | wc -l)
[ "$N_ROTO" -le 5 ] && pass_check "$N_ROTO dangling symlinks" || fail_check "$N_ROTO dangling symlinks"

# File names, not just contents: the sweep above uses grep -rl, which looks
# inside files. A file that CARRIES the builder's name in its own path (mise
# keeps one per trusted directory) passed clean and shipped inside the image.
if [ "$OLD" != "$NEW" ]; then
  # NOTE: as a WORD, never as a substring. With "*$OLD*" and VM_USER=dev, this
  # matched /etc/udev and the rm -rf left the image without a single udev
  # rule; with VM_USER=arch it matched /home/omarchy entirely. The build
  # user's name is chosen via the environment, so the pattern has to require
  # that $OLD appear delimited by something non-alphanumeric.
  RX_OLD=".*/([^/]*[^[:alnum:]])?$OLD([^[:alnum:]][^/]*)?"
  mapfile -t PORNOMBRE < <(find /home/"$NEW" /etc /usr/local /opt -xdev -mindepth 1 \
      -regextype posix-extended -regex "$RX_OLD" 2>/dev/null)
  if [ "${#PORNOMBRE[@]}" -gt 0 ] && [ -n "${PORNOMBRE[0]:-}" ]; then
    echo "  removing ${#PORNOMBRE[@]} file(s) whose NAME carries '$OLD':"
    for f in "${PORNOMBRE[@]}"; do echo "    $f"; rm -rf "$f"; done
  fi
  RESTAN=$(find /home/"$NEW" /etc /usr/local /opt -xdev -mindepth 1 \
      -regextype posix-extended -regex "$RX_OLD" 2>/dev/null | wc -l)
  [ "$RESTAN" -eq 0 ] && pass_check "no file name mentions $OLD" || fail_check "$RESTAN names still mention $OLD"
fi

# The clipboard: the five pieces that can break it.
[ -x /usr/local/bin/omarchy-arm-vdagent ] && pass_check "clipboard agent installed" || fail_check "missing /usr/local/bin/omarchy-arm-vdagent"
grep -qs -- ' -X ' /etc/systemd/system/spice-vdagentd.service.d/override.conf \
  && pass_check "spice-vdagentd with -X" || fail_check "spice-vdagentd without -X: the clipboard won't work"
[ -e "/home/$NEW/.config/systemd/user/graphical-session.target.wants/omarchy-arm-vdagent.service" ] \
  && pass_check "agent enabled in the graphical session" \
  || fail_check "the agent wasn't left enabled for $NEW"
if grep -vs -- '^[[:space:]]*--' "/home/$NEW/.config/hypr/autostart.lua" 2>/dev/null | grep -qs spice-vdagent; then
  fail_check "autostart.lua launches the official agent: vdagentd will disconnect both"
else
  pass_check "autostart.lua doesn't launch the official agent"
fi

[ "$(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l)" -eq 0 ] && pass_check "no ssh host keys" || fail_check "ssh host keys remain"

# Binaries compiled inside the VM: the build path stays in their debug info.
# grep -rl doesn't see it because it looks at text, not symbols.
if [ "$OLD" != "$NEW" ]; then
  # strings might not be present (it comes from binutils); if it's missing, we
  # say so instead of making up a verdict.
  if ! command -v strings >/dev/null 2>&1; then
    echo "  ? /usr/local/bin binaries: can't check without 'strings'"
  else
    SUCIOS=""
    for b in /usr/local/bin/*; do
      [ -f "$b" ] || continue
      strings "$b" 2>/dev/null | grep -q "/home/$OLD" && SUCIOS="$SUCIOS $b"
    done
    [ -z "$SUCIOS" ] && pass_check "no /usr/local/bin binary mentions the builder" \
                     || fail_check "binaries with the builder's path inside:$SUCIOS (see RUSTFLAGS/CARGO_HOME in stage3)"
  fi
fi
[ -f /root/failed-packages.txt ] && fail_check "/root/failed-packages.txt remains" \
                                 || pass_check "no builder residue left in /root"

echo ""
if [ "$FAILURES" -ne 0 ]; then
  echo "==> SANITIZE_FAILED: $FAILURES invariant(s) broken; this image CANNOT be distributed"
  exit 1
fi
echo ""
echo "==> SANITIZE_OK"
__PAYLOAD_PROVISION_SANITIZE_SH__
chmod +x "$W/provision/sanitize.sh"

mkdir -p "$W/provision"
cat > "$W/provision/extras.sh" <<'__PAYLOAD_PROVISION_EXTRAS_SH__'
#!/bin/bash
#
#  omarchy-arm-extras — installs apps on Arch Linux ARM that aren't in the image
#  ───────────────────────────────────────────────────────────────────────────
#  Proprietary apps are deliberately NOT bundled inside: packaging them into a
#  .zip that gets distributed would mean redistributing third-party binaries.
#  This script downloads them from their OFFICIAL source, on your machine and
#  at your own discretion.
#
#  Almost all of them have an official arm64 build. The ones already bundled
#  in the image (free software) are marked as [already installed] and skipped.
#
#  Usage:
#    omarchy-arm-extras                    interactive menu
#    omarchy-arm-extras --list             see what it can install
#    omarchy-arm-extras 1password obsidian install specific items
#    omarchy-arm-extras --all              everything missing
#    omarchy-arm-extras --force <key>      reinstall even if already present
#
set -uo pipefail

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_hi=$'\033[1;36m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
title() { echo; echo "${c_hi}━━━ $* ━━━${c_off}"; }
info()  { echo "  $*"; }
ok()    { echo "  ${c_ok}✓${c_off} $*"; }
warn()  { echo "  ${c_warn}!${c_off} $*" >&2; }
fail()  { echo "  ${c_err}✗${c_off} $*" >&2; }

# /tmp is tmpfs and limited by RAM: compiling .NET or OBS there runs out of
# space halfway through. Work happens on real disk instead.
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-arm-extras"
OK_LIST=(); KO_LIST=()

# ── catalog ─────────────────────────────────────────────────────────────────
#  key|title|description
CATALOG=(
  "1password|1Password|Password manager. Official arm64 tarball from AgileBits"
  "1password-cli|1Password CLI|The op command. Official static arm64 binary"
  "obsidian|Obsidian|Markdown notes. Official arm64 AppImage"
  "typora|Typora|WYSIWYG markdown editor. Official arm64 package via AUR"
  "localsend|LocalSend|Send files between devices. Official arm64 build"
  "chrome|Google Chrome|Ships Widevine for arm64: enables Spotify and Netflix web"
  "spotify-web|Spotify (webapp)|Launcher for open.spotify.com + remaps SUPER+SHIFT+M"
  "pinta|Pinta|Image editor. Built with Microsoft's arm64 .NET"
  "obs|OBS Studio|Capture and streaming. Built without the browser plugin"
)

catalog_keys()  { printf '%s\n' "${CATALOG[@]}" | cut -d'|' -f1; }
catalog_title() { printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" '$1==k{print $2}'; }
catalog_desc()  { printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" '$1==k{print $3}'; }

# ── utilities ───────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# Pinta and OBS Studio are free software and ship inside the image; the rest
# don't. Without this check, `--all` would recompile OBS from scratch (half an
# hour) just to reinstall what's already there.
is_installed() {
  case "$1" in
    1password)     pacman -Q 1password        >/dev/null 2>&1 || [ -d /opt/1Password ] ;;
    1password-cli) have op ;;
    obsidian)      [ -d /opt/obsidian ] ;;
    typora)        pacman -Q typora           >/dev/null 2>&1 ;;
    localsend)     pacman -Q localsend-bin    >/dev/null 2>&1 ;;
    chrome)        pacman -Q google-chrome    >/dev/null 2>&1 || have google-chrome-stable ;;
    spotify-web)   grep -q "open.spotify.com" "$HOME/.config/hypr/bindings.lua" 2>/dev/null ;;
    pinta)         pacman -Q pinta            >/dev/null 2>&1 ;;
    obs)           pacman -Q obs-studio       >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

need_sudo() {
  sudo -n true 2>/dev/null && return 0
  info "sudo is required to install packages."
  sudo -v || { fail "no privileges"; return 1; }
}

# Builds an AUR package while working around the usual ARM traps:
#  · the clone URL uses the PackageBase, which isn't always the package name
#  · many PKGBUILDs declare arch=(x86_64) by default, not due to incompatibility
#  · a PKGBUILD can produce several subpackages, and only one may have the broken dependency
aur_build() {
  # A single `local` expands ALL values before assigning any of them, so
  # $pkg wouldn't exist yet when building $dir, and with set -u the script aborts.
  local pkg="$1" want="${2:-$1}"
  local dir="$WORK/$pkg" base
  pacman -Q "$want" >/dev/null 2>&1 && { ok "$want already installed"; return 0; }

  base=$(curl -fsSL --max-time 20 "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" \
         | sed -n 's/.*"PackageBase":"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$base" ] || base="$pkg"

  rm -rf "$dir"; mkdir -p "$WORK"
  git clone -q "https://aur.archlinux.org/$base.git" "$dir" 2>/dev/null
  [ -f "$dir/PKGBUILD" ] || { fail "couldn't clone $pkg (base: $base)"; return 1; }

  # Several PKGBUILDs verify the upstream signature in check(). If the key
  # isn't in the keyring, makepkg aborts. The ones the PKGBUILD itself
  # declares are imported, instead of skipping verification.
  local keys k
  keys=$(sed -n '/^validpgpkeys=(/,/)/p' "$dir/PKGBUILD" | grep -oE '[0-9A-Fa-f]{40}')
  for k in $keys; do
    [ ${#k} -ge 16 ] || continue
    gpg --list-keys "$k" >/dev/null 2>&1 && continue
    info "importing GPG key ${k: -8}"
    gpg --keyserver keyserver.ubuntu.com --recv-keys "$k" >/dev/null 2>&1 \
      || gpg --keyserver keys.openpgp.org --recv-keys "$k" >/dev/null 2>&1 \
      || warn "couldn't import ${k: -8}: signature verification will fail"
  done

  if ! grep -qE "^arch=\(.*\b(aarch64|any)\b" "$dir/PKGBUILD"; then
    sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
    info "arch= patched to include aarch64"
  fi

  ( cd "$dir" && makepkg -si --noconfirm --needed --noprogressbar ) >"$dir/build.log" 2>&1 && return 0
  fail "build of $pkg failed — log: $dir/build.log"
  tail -5 "$dir/build.log" | sed 's/^/      /'
  return 1
}

# ── installers ──────────────────────────────────────────────────────────────

do_1password() {
  title "1Password"
  info "AgileBits publishes arm64 ONLY as a tarball: there's no .deb or .rpm for this architecture."
  local url=https://downloads.1password.com/linux/tar/stable/aarch64/1password-latest.tar.gz
  mkdir -p "$WORK"; rm -rf "$WORK/1p"; mkdir -p "$WORK/1p"
  curl -fL --progress-bar "$url" -o "$WORK/1p/1p.tar.gz" || { fail "download failed"; return 1; }
  # It's a password manager: the signature is verified before installing it.
  local KEY=3FEF9748469ADBE15DA7CA80AC2D62742012EA22
  if curl -fsSL "$url.sig" -o "$WORK/1p/1p.tar.gz.sig" 2>/dev/null; then
    gpg --list-keys "$KEY" >/dev/null 2>&1 \
      || gpg --keyserver keyserver.ubuntu.com --recv-keys "$KEY" >/dev/null 2>&1 \
      || gpg --keyserver keys.openpgp.org --recv-keys "$KEY" >/dev/null 2>&1
    if gpg --verify "$WORK/1p/1p.tar.gz.sig" "$WORK/1p/1p.tar.gz" >/dev/null 2>&1; then
      ok "AgileBits GPG signature verified"
    else
      fail "SIGNATURE DOES NOT VERIFY — aborting installation"; return 1
    fi
  else
    warn "no .sig available; installing without verifying the signature"
  fi
  tar -xzf "$WORK/1p/1p.tar.gz" -C "$WORK/1p" || { fail "couldn't extract"; return 1; }
  local src; src=$(find "$WORK/1p" -maxdepth 1 -type d -name '1password-*' | head -1)
  [ -n "$src" ] || { fail "the tarball doesn't have the expected shape"; return 1; }
  sudo mkdir -p /opt/1Password
  sudo cp -a "$src"/. /opt/1Password/
  ( cd /opt/1Password && sudo ./after-install.sh ) >/dev/null 2>&1 || warn "after-install.sh reported errors (usually harmless)"
  have 1password && ok "$(1password --version 2>/dev/null | head -1 || echo installed)" || { fail "didn't end up on PATH"; return 1; }
  info "${c_dim}On Hyprland it's best to launch it with --ozone-platform=wayland${c_off}"
}

do_1password_cli() { title "1Password CLI"; aur_build 1password-cli && ok "$(op --version 2>/dev/null)"; }

do_obsidian() {
  title "Obsidian"
  info "There's an official AppImage and tarball for arm64. The tarball is used: it doesn't depend on fuse2."
  # NOTE: releases/latest can be an Android-ONLY release (a stray .apk).
  # Need to find the latest one that actually publishes the desktop arm64 tarball.
  local url
  url=$(curl -fsSL --max-time 30 "https://api.github.com/repos/obsidianmd/obsidian-releases/releases?per_page=15" \
        | grep -oE '"browser_download_url": *"[^"]*obsidian-[0-9.]+-arm64\.tar\.gz"' \
        | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
  [ -n "$url" ] || { fail "found no arm64 tarball in the latest releases"; return 1; }
  info "$(basename "$url")"
  mkdir -p "$WORK"; curl -fL --progress-bar "$url" -o "$WORK/obsidian.tar.gz" || { fail "download failed"; return 1; }
  sudo rm -rf /opt/obsidian; sudo mkdir -p /opt/obsidian
  sudo tar -xzf "$WORK/obsidian.tar.gz" -C /opt/obsidian --strip-components=1 || { fail "couldn't extract"; return 1; }
  sudo ln -sfn /opt/obsidian/obsidian /usr/local/bin/obsidian
  sudo install -Dm644 /dev/stdin /usr/local/share/applications/obsidian.desktop <<'DESK'
[Desktop Entry]
Name=Obsidian
Exec=obsidian --ozone-platform-hint=auto %u
Icon=obsidian
Type=Application
Categories=Office;
MimeType=x-scheme-handler/obsidian;
DESK
  [ -f /opt/obsidian/resources/app.asar ] && sudo find /opt/obsidian -name 'icon.png' -exec \
    sudo install -Dm644 {} /usr/local/share/icons/hicolor/512x512/apps/obsidian.png \; 2>/dev/null
  ok "Obsidian installed in /opt/obsidian ($(basename "$url"))"
}

do_typora() {
  title "Typora"
  info "The AUR package 'typora' pulls the official arm64 .deb. Don't use typora-electron: it requires electron42, which doesn't exist on ARM."
  aur_build typora && ok "$(pacman -Q typora)"
}

do_localsend() { title "LocalSend"; aur_build localsend-bin localsend-bin && ok "$(pacman -Q localsend-bin)"; }

do_chrome() {
  title "Google Chrome"
  info "Chrome arm64 includes Widevine (the DRM that Spotify and Netflix web require)."
  info "Chromium from the repos does NOT ship it, and the chromium-widevine package is x86_64 only."
  aur_build google-chrome || return 1
  ok "$(pacman -Q google-chrome)"
  info "${c_dim}Check the DRM at chrome://components → 'Widevine Content Decryption Module'${c_off}"
}

do_spotify_web() {
  title "Spotify (webapp)"
  # Omarchy treats Spotify as a native package, not a webapp — and that package
  # is x86_64. On ARM the working path is the web, which needs Widevine.
  if ! have google-chrome-stable; then
    warn "without Google Chrome the Spotify web player won't play: install 'chrome' first"
  fi
  if have omarchy-webapp-install; then
    omarchy-webapp-install "Spotify" "https://open.spotify.com" \
      "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/spotify.png" \
      "$(have google-chrome-stable && echo 'google-chrome-stable --app=https://open.spotify.com')" \
      >/dev/null 2>&1 && ok "launcher created in the applications menu"
  else
    warn "omarchy-webapp-install is not available"
  fi
  # Remap SUPER+SHIFT+M, which in Omarchy points to the native binary
  local f="$HOME/.config/hypr/bindings.lua"
  if [ -f "$f" ] && ! grep -q "open.spotify.com" "$f"; then
    cat >> "$f" <<'LUA'

-- Spotify has no native client for aarch64: SUPER+SHIFT+M opens the webapp.
-- Needs Google Chrome, which is what ships Widevine on arm64.
o.bind("SUPER + SHIFT + M", "Spotify", o.launch("google-chrome-stable --app=https://open.spotify.com"))
LUA
    ok "SUPER+SHIFT+M remapped (restart the session to apply it)"
  fi
  info "${c_dim}Terminal alternative, already installed: spotify-player${c_off}"
}

do_pinta() {
  title "Pinta"
  info "Microsoft does publish .NET for linux-arm64; Arch only packages it for x86_64."
  info "The runtime is installed from the official tarball, then the Pinta package, which is arch=any."
  aur_build dotnet-runtime-bin dotnet-runtime-bin || { fail "can't continue without the .NET runtime"; return 1; }
  local url=https://geo.mirror.pkgbuild.com/extra/os/x86_64/
  local file; file=$(curl -fsSL --max-time 30 "$url" | grep -o 'pinta-[0-9][^"]*-any\.pkg\.tar\.zst' | sort -V | tail -1)
  [ -n "$file" ] || { fail "couldn't find the Pinta package"; return 1; }
  info "$file  ${c_dim}(the path says x86_64 but the package is arch=any)${c_off}"
  mkdir -p "$WORK"; curl -fL --progress-bar "$url$file" -o "$WORK/$file" || return 1
  sudo pacman -U --noconfirm "$WORK/$file" >/dev/null 2>&1 && ok "$(pacman -Q pinta)" || { fail "pacman -U failed"; return 1; }
  warn "stays outside the update manager: each new version has to be repeated by hand"
}

do_obs() {
  title "OBS Studio"
  info "OBS builds fine on aarch64. The only thing blocking it on Arch Linux ARM is the"
  info "browser subpackage, whose 'cef' only exists for x86_64. It gets disabled."
  warn "building Qt6 + OBS inside the VM takes a good while"
  local dir="$WORK/obs-studio"
  rm -rf "$dir"; mkdir -p "$WORK"
  git clone -q --depth 1 https://gitlab.archlinux.org/archlinux/packaging/packages/obs-studio.git "$dir" \
    || { fail "couldn't clone Arch's PKGBUILD"; return 1; }
  cd "$dir" || return 1
  sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" PKGBUILD
  # NOTE: 'cef' is on the SAME line as makedepends=, not its own, so
  # it has to be removed as a token, not as a whole line.
  sed -i "s/'cef'[[:space:]]*//g" PKGBUILD
  sed -i "/cef_api_versions\.h/d; /-DCEF_API_VERSION/d; /_cef_api_version/d" PKGBUILD
  sed -i 's/-DENABLE_BROWSER=ON/-DENABLE_BROWSER=OFF/' PKGBUILD
  # package_obs-studio() sets the browser plugin files aside for the separate
  # subpackage. Without browser those files don't exist and the `mv` aborts
  # packaging AFTER everything has already been built: those two lines have to go.
  sed -i '/mv \$pkgdir\/usr\/lib\/obs-plugins\/{obs-browser-page,obs-browser.so}/d' PKGBUILD
  sed -i '/mv \$pkgdir\/usr\/share\/obs\/obs-plugins\/obs-browser /d' PKGBUILD
  # and the plugin's patches, which no longer apply to anything
  sed -i '/patch -d plugins\/obs-browser/d' PKGBUILD
  # source=() and sha256sums=() are NOT touched: deleting entries from one without
  # the other makes makepkg abort with "Integrity checks differ in size from the source
  # array". Downloading extra obs-browser is just bandwidth.
  sed -i '/INSTALL_RPATH.*cef/d' PKGBUILD
  # The browser subpackage is no longer generated
  sed -i '/^package_obs-studio-plugin-browser()/,/^}/d' PKGBUILD
  sed -i "s/^pkgname=(.*)/pkgname=('obs-studio')/" PKGBUILD
  info "PKGBUILD patched: aarch64, no CEF, no browser plugin"
  if makepkg -si --noconfirm --needed --noprogressbar >"$dir/build.log" 2>&1; then
    ok "$(pacman -Q obs-studio)"
    info "${c_dim}No hardware acceleration in the VM: it will encode with x264 on CPU${c_off}"
  else
    fail "build failed — log: $dir/build.log"
    tail -6 "$dir/build.log" | sed 's/^/      /'
    return 1
  fi
}

run_item() {
  local k="$1"
  if [ "${FORCE:-0}" != "1" ] && is_installed "$k"; then
    title "$(catalog_title "$k")"
    ok "already comes installed in this image (--force to reinstall)"
    return 0
  fi
  case "$k" in
    1password)     do_1password ;;
    1password-cli) do_1password_cli ;;
    obsidian)      do_obsidian ;;
    typora)        do_typora ;;
    localsend)     do_localsend ;;
    chrome)        do_chrome ;;
    spotify-web)   do_spotify_web ;;
    pinta)         do_pinta ;;
    obs)           do_obs ;;
    *) fail "unknown '$k'"; return 1 ;;
  esac
}

show_list() {
  echo
  echo "${c_hi}Apps installed from their official source${c_off}"
  echo "${c_dim}Proprietary apps aren't bundled in on purpose: redistributing their binaries"
  echo "in a distributed image would be problematic. Here they get downloaded to your"
  echo "machine, from the vendor's site.${c_off}"
  echo
  local k
  while read -r k; do
    if is_installed "$k"; then
      printf "  ${c_hi}%-15s${c_off} %s ${c_dim}[already installed]${c_off}\n" "$k" "$(catalog_desc "$k")"
    else
      printf "  ${c_hi}%-15s${c_off} %s\n" "$k" "$(catalog_desc "$k")"
    fi
  done < <(catalog_keys)
  echo
  echo "${c_dim}Usage: omarchy-arm-extras <key> [key...]   ·   --all for everything${c_off}"
  echo
}

# ── main ────────────────────────────────────────────────────────────────────
SELECTED=()
FORCE=0
if [ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ]; then FORCE=1; shift; fi
case "${1:-}" in
  --list|-l) show_list; exit 0 ;;
  --all|-a)  mapfile -t SELECTED < <(catalog_keys) ;;
  -h|--help) sed -n '3,20p' "$0" | sed 's/^#\{0,2\} \{0,1\}//'; exit 0 ;;
  "")
    if have gum; then
      show_list
      mapfile -t SELECTED < <(
        while read -r k; do printf '%s — %s\n' "$k" "$(catalog_title "$k")"; done < <(catalog_keys) \
        | gum choose --no-limit --header "Select what to install (space to mark, enter to confirm)" \
        | cut -d' ' -f1
      )
    else
      show_list; exit 0
    fi ;;
  *) SELECTED=("$@") ;;
esac

[ ${#SELECTED[@]} -gt 0 ] || { info "nothing selected"; exit 0; }

need_sudo || exit 1
mkdir -p "$WORK"

for k in "${SELECTED[@]}"; do
  [ -z "$k" ] && continue
  if run_item "$k"; then OK_LIST+=("$k"); else KO_LIST+=("$k"); fi
done

title "Summary"
[ ${#OK_LIST[@]} -gt 0 ] && ok "installed: ${OK_LIST[*]}"
if [ ${#KO_LIST[@]} -gt 0 ]; then
  fail "failed: ${KO_LIST[*]}"
  # The work directory isn't deleted: it holds the build.log files, which are
  # the only way to figure out why it failed.
  info "logs in $WORK/<package>/build.log"
else
  rm -rf "$WORK"
fi
echo
__PAYLOAD_PROVISION_EXTRAS_SH__
chmod +x "$W/provision/extras.sh"

mkdir -p "$W/provision"
cat > "$W/provision/armsync.sh" <<'__PAYLOAD_PROVISION_ARMSYNC_SH__'
#!/bin/bash
# post-update hook for ARM installs.
#
# On this install, Omarchy doesn't come from its pacman package (which only
# exists for x86_64) but from a git checkout. omarchy-update-dev only runs
# `git pull` when OMARCHY_PATH points OUTSIDE /usr/share/omarchy, and here it
# points right at it, so without this hook the Omarchy tree would never get
# updated: the system would receive new packages but Omarchy's scripts,
# themes, and config would stay frozen at the cloned version.
set -uo pipefail
TREE=/usr/share/omarchy

git -C "$TREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# The tree may be owned by the user (dev VM) or by root (distributed image)
if [ -w "$TREE/.git" ]; then GIT=(git -C "$TREE"); else GIT=(sudo git -C "$TREE"); fi

echo -e "\e[32m\nUpdating the Omarchy tree (git checkout)\e[0m"
before=$("${GIT[@]}" rev-parse --short HEAD 2>/dev/null)
if ! "${GIT[@]}" pull --ff-only 2>&1 | sed 's/^/  /'; then
  echo "  couldn't fast-forward; tree left as-is"
  exit 0
fi
after=$("${GIT[@]}" rev-parse --short HEAD 2>/dev/null)
if [ "$before" = "$after" ]; then echo "  already up to date ($after)"; exit 0; fi
echo "  $before → $after"

# Symlink the new binaries, without touching ARM's own wrapper scripts
# (omarchy-pkg-add is a real file, not a symlink: it must not be overwritten).
n=0
for f in "$TREE"/bin/*; do
  [ -f "$f" ] || continue
  b=$(basename "$f"); t="/usr/bin/$b"
  [ -e "$t" ] && [ ! -L "$t" ] && continue
  [ -L "$t" ] && continue
  # Point at /usr/share/omarchy, not $TREE: that path survives the user
  # rename the sanitizer does (see stage3).
  sudo ln -sfn "/usr/share/omarchy/bin/$b" "$t" 2>/dev/null && n=$((n+1))
done
[ "$n" -gt 0 ] && echo "  $n new binaries linked into /usr/bin"
# Symlinks pointing at commands already removed from the tree
sudo find /usr/bin -xtype l -delete 2>/dev/null || true
exit 0
__PAYLOAD_PROVISION_ARMSYNC_SH__
chmod +x "$W/provision/armsync.sh"

cat > "$W/provision/clipbrd.sh" <<'__PAYLOAD_PROVISION_CLIPBRD_SH__'
#!/bin/bash
#
#  omarchy-arm-clipboard — clipboard shared with the Mac, via UTM's shared
#  folder.
#
#  WHY THIS IS NEEDED
#  UTM offers "Share Clipboard", but that only works if the guest runs
#  spice-vdagent, and spice-vdagent's clipboard is pure X11: its clipboard.c
#  delegates everything to vdagent_x11_* and there isn't a single reference
#  to wlr-data-control in its code. Under Hyprland (native Wayland) it can't
#  work, no matter that the service starts.
#
#  HOW IT WORKS
#  Watches /mnt/share/.clipboard in both directions: if the file changes,
#  it copies it to the guest's clipboard; if the guest's clipboard changes,
#  it writes it to the file. On the Mac, an equivalent script does the same
#  with pbcopy/pbpaste. Text only.
#
#  USAGE
#    omarchy-arm-clipboard             watches (launched by the user service)
#    omarchy-arm-clipboard --install   installs the service and starts it
#    omarchy-arm-clipboard --host      prints the script for the Mac
#
set -uo pipefail

SHARE="${OMARCHY_CLIPBOARD_DIR:-/mnt/share}"
FILE="$SHARE/.clipboard"
INTERVAL="${OMARCHY_CLIPBOARD_INTERVAL:-1}"

usage() { sed -n '3,26p' "$0" | sed 's/^#\{0,2\} \{0,1\}//'; }

install() {
  mkdir -p ~/.config/systemd/user
  cat > ~/.config/systemd/user/omarchy-arm-clipboard.service <<'UNIT'
[Unit]
Description=Clipboard shared with the host (via UTM shared folder)
After=graphical-session.target
PartOf=graphical-session.target
ConditionEnvironment=WAYLAND_DISPLAY

[Service]
Type=simple
ExecStart=/usr/local/bin/omarchy-arm-clipboard
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now omarchy-arm-clipboard.service && echo "service active"
  systemctl --user --no-pager status omarchy-arm-clipboard.service | head -5
}

host_script() {
  cat <<'MACEOF'
#!/bin/bash
# Run THIS ON THE MAC. Syncs the clipboard with the VM through the folder
# you have shared in the VM's settings in UTM.
#   ./clipboard-mac.sh ~/path/to/shared/folder
set -uo pipefail
DIR="${1:?usage: $0 <folder shared with the VM>}"
F="$DIR/.clipboard"
mkdir -p "$DIR"; touch "$F"
last_local=""; last_remote="$(cat "$F" 2>/dev/null || true)"
while :; do
  current="$(pbpaste 2>/dev/null || true)"
  if [ "$current" != "$last_local" ] && [ -n "$current" ]; then
    printf '%s' "$current" > "$F"; last_local="$current"; last_remote="$current"
  fi
  remote="$(cat "$F" 2>/dev/null || true)"
  if [ "$remote" != "$last_remote" ] && [ -n "$remote" ]; then
    printf '%s' "$remote" | pbcopy; last_remote="$remote"; last_local="$remote"
  fi
  sleep 1
done
MACEOF
}

watch() {
  command -v wl-paste >/dev/null || { echo "missing wl-clipboard" >&2; exit 1; }
  if [ ! -d "$SHARE" ]; then
    echo "no shared folder at $SHARE." >&2
    echo "In UTM: VM Settings -> Sharing -> pick a folder, then restart." >&2
    exit 1
  fi
  touch "$FILE" 2>/dev/null || { echo "can't write to $FILE" >&2; exit 1; }
  local last_local last_remote current remote
  last_local="$(wl-paste --no-newline 2>/dev/null || true)"
  last_remote="$(cat "$FILE" 2>/dev/null || true)"
  while :; do
    # guest -> file
    current="$(wl-paste --no-newline 2>/dev/null || true)"
    if [ "$current" != "$last_local" ] && [ -n "$current" ]; then
      printf '%s' "$current" > "$FILE"
      last_local="$current"; last_remote="$current"
    fi
    # file -> guest
    remote="$(cat "$FILE" 2>/dev/null || true)"
    if [ "$remote" != "$last_remote" ] && [ -n "$remote" ]; then
      printf '%s' "$remote" | wl-copy
      last_remote="$remote"; last_local="$remote"
    fi
    sleep "$INTERVAL"
  done
}

case "${1:-}" in
  --install) install ;;
  --host)    host_script ;;
  -h|--help) usage ;;
  "")        watch ;;
  *)         echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
esac
__PAYLOAD_PROVISION_CLIPBRD_SH__
chmod +x "$W/provision/clipbrd.sh"

cat > "$W/provision/vdagent.py" <<'__PAYLOAD_PROVISION_VDAGENT_PY__'
#!/usr/bin/env python3
"""
omarchy-arm-vdagent — shared clipboard between the host and Hyprland.

HOW THE SPICE CLIPBOARD WORKS, AND WHY THIS EXISTS

    The host's SPICE client does NOT talk to the session agent: it talks to
    the spice-vdagentd daemon over the virtio port. The daemon, in turn,
    multiplexes out to the session agents over a Unix socket
    (/run/spice-vdagentd/spice-vdagent-sock). That's what makes it work on
    any other VM.

    The official agent (spice-vdagent) implements that side, but hands the
    clipboard off to X11: vdagent.c:421 calls
    vdagent_clipboards_new(vdagent_display_get_x11(...)) and there isn't a
    single reference to wlr-data-control anywhere in its repository. Under
    Hyprland it starts up and dies with "cannot open display".

    This program fills exactly that gap: it speaks the udscs protocol with
    spice-vdagentd just like the official agent, and on the other side uses
    wl-copy/wl-paste. The daemon is still the one talking to the host.

    One detail that matters: vdagentd only serves the agent of seat0's
    ACTIVE session (vdagentd.c:746). In a VM where Hyprland is launched by
    SDDM that check usually fails, so the daemon has to be started with -X
    (disable-session-integration, vdagentd.c:1258).

    Text only. No images, no files.
"""
import os, sys, socket, struct, subprocess, threading, time, signal

SOCK = os.environ.get("VDAGENTD_SOCK", "/run/spice-vdagentd/spice-vdagent-sock")

# vdagentd-proto.h
GUEST_XORG_RESOLUTION = 0
MONITORS_CONFIG       = 1
CLIPBOARD_GRAB        = 2
CLIPBOARD_REQUEST     = 3
CLIPBOARD_DATA        = 4
CLIPBOARD_RELEASE     = 5
VERSION               = 6
CLIENT_DISCONNECTED   = 12

SEL_CLIPBOARD = 0          # VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD
UTF8_TYPE     = 1          # VD_AGENT_CLIPBOARD_UTF8_TEXT

DEBUG = bool(os.environ.get("VDAGENT_DEBUG"))
def log(*a):
    if DEBUG: print("[vdagent]", *a, file=sys.stderr, flush=True)


class Agent:
    def __init__(self, sock):
        self.s = sock
        self.lock = threading.Lock()
        self.last_local = None
        self.waiting = threading.Event()
        self.received = None

    def send_(self, kind, arg1=0, arg2=0, data=b""):
        header = struct.pack("<IIII", kind, arg1, arg2, len(data))
        with self.lock:
            self.s.sendall(header + data)
        log("→", kind, arg1, arg2, len(data))

    def _read(self, n):
        b = b""
        while len(b) < n:
            t = self.s.recv(n - len(b))
            if not t: raise EOFError
            b += t
        return b

    def loop_(self):
        while True:
            try:
                kind, a1, a2, size = struct.unpack("<IIII", self._read(16))
                data = self._read(size) if size else b""
            except (EOFError, OSError) as e:
                log("socket closed:", e); return
            log("←", kind, a1, a2, size)

            if kind == CLIPBOARD_GRAB:
                # the host is offering something: request it
                self.send_(CLIPBOARD_REQUEST, SEL_CLIPBOARD, UTF8_TYPE)

            elif kind == CLIPBOARD_REQUEST:
                text = read_clipboard() or ""
                self.send_(CLIPBOARD_DATA, SEL_CLIPBOARD, UTF8_TYPE,
                           text.encode("utf-8"))

            elif kind == CLIPBOARD_DATA:
                if a2 == UTF8_TYPE:
                    text = data.decode("utf-8", "replace")
                    write_clipboard(text)
                    self.last_local = text
                    log("  received from host:", len(text), "bytes")

            elif kind == VERSION:
                log("  vdagentd version:", data.decode("utf8", "replace").strip())


def read_clipboard():
    try:
        r = subprocess.run(["wl-paste", "--no-newline", "--type", "text/plain"],
                           capture_output=True, timeout=5)
        return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None
    except Exception:
        return None


def write_clipboard(text):
    try:
        subprocess.run(["wl-copy", "--type", "text/plain;charset=utf-8"],
                       input=text.encode("utf-8"), timeout=5)
    except Exception as e:
        log("wl-copy failed:", e)


def resolution():
    """The real resolution, if hyprctl is available; otherwise a sane default."""
    try:
        r = subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, timeout=4)
        if r.returncode == 0:
            import json
            m = json.loads(r.stdout)[0]
            return int(m["width"]), int(m["height"])
    except Exception:
        pass
    return 1920, 1200


def watch(ag):
    """If the user copies something inside the VM, offer it to the host."""
    while True:
        t = read_clipboard()
        if t is not None and t != ag.last_local:
            ag.last_local = t
            if t:
                ag.send_(CLIPBOARD_GRAB, SEL_CLIPBOARD, 0,
                          struct.pack("<I", UTF8_TYPE))
        time.sleep(1)


def main():
    for c in ("wl-paste", "wl-copy"):
        if subprocess.run(["sh", "-c", f"command -v {c}"],
                          capture_output=True).returncode != 0:
            print(f"missing {c} (wl-clipboard package)", file=sys.stderr); return 1
    if not os.path.exists(SOCK):
        print(f"{SOCK} does not exist.", file=sys.stderr)
        print("Start the daemon:  sudo systemctl start spice-vdagentd",
              file=sys.stderr)
        return 1

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    ag = Agent(s)

    # The official agent announces its resolution right after connecting;
    # vdagentd uses that to know there's a live graphical session behind it.
    # struct vdagentd_guest_xorg_resolution = 5 ints: width, height, x, y,
    # display_id (vdagentd-proto.h:51). If the size doesn't match exactly,
    # vdagentd just disconnects the agent (vdagentd.c:1088).
    width, height = resolution()
    ag.send_(GUEST_XORG_RESOLUTION, width, height,
             struct.pack("<iiiii", width, height, 0, 0, 0))

    ag.last_local = read_clipboard()
    threading.Thread(target=watch, args=(ag,), daemon=True).start()
    try:
        ag.loop_()
    except KeyboardInterrupt:
        pass
    finally:
        s.close()
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    sys.exit(main())
__PAYLOAD_PROVISION_VDAGENT_PY__
chmod +x "$W/provision/vdagent.py"

cat > "$W/provision/share.sh" <<'__PAYLOAD_PROVISION_SHARE_SH__'
#!/bin/bash
#
#  omarchy-arm-share — mounts the folder you share from UTM.
#
#  UTM has two modes and the user picks one in VM Settings → Sharing:
#
#    VirtFS       9p device with mount_tag "share". Mounts directly.
#    SPICE WebDAV virtio port org.spice-space.webdav.0. spice-webdavd serves
#                 it at http://localhost:9843/ and it's mounted with davfs2.
#
#  This script detects which one is active and does whatever's needed. With no
#  arguments it mounts; with --umount it unmounts; with --status it reports what's there.
#
set -uo pipefail
MOUNT_POINT="${OMARCHY_SHARE_MNT:-/mnt/share}"
TAG=share
WEBDAV_PORT=/dev/virtio-ports/org.spice-space.webdav.0
URL=http://localhost:9843/

has_9p()     { grep -qw 9p /proc/filesystems 2>/dev/null && [ -e /sys/bus/virtio/drivers/9pnet_virtio ]; }
has_webdav() { [ -e "$WEBDAV_PORT" ]; }
mounted()    { mountpoint -q "$MOUNT_POINT"; }

status() {
  echo "  mount point:      $MOUNT_POINT"
  echo "  mounted:          $(mounted && echo yes || echo no)"
  echo "  VirtFS mode (9p): $(has_9p && echo available || echo no)"
  echo "  SPICE WebDAV mode:$(has_webdav && echo ' available' || echo ' no')"
  if has_webdav; then
    echo "  spice-webdavd:    $(systemctl is-active spice-webdavd 2>&1)"
  fi
  mounted && { echo "  contents:"; ls -la "$MOUNT_POINT" 2>/dev/null | head -6 | sed 's/^/    /'; }
}

mount_() {
  mounted && { echo "already mounted at $MOUNT_POINT"; return 0; }
  sudo mkdir -p "$MOUNT_POINT"

  # 1) VirtFS: simplest option, if the device is present
  if sudo mount -t 9p -o trans=virtio,version=9p2000.L,rw,msize=512000 "$TAG" "$MOUNT_POINT" 2>/dev/null; then
    echo "mounted via VirtFS (9p) at $MOUNT_POINT"; return 0
  fi

  # 2) SPICE WebDAV
  if has_webdav; then
    sudo systemctl start spice-webdavd 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      curl -s -m 2 -o /dev/null "$URL" && break
      sleep 1
    done
    if ! curl -s -m 3 -o /dev/null "$URL"; then
      echo "spice-webdavd not responding at $URL" >&2
      echo "  systemctl status spice-webdavd" >&2
      return 1
    fi
    # davfs2 asks for username and password: not needed here
    if printf '\n\n' | sudo mount -t davfs -o rw,uid=$(id -u),gid=$(id -g) "$URL" "$MOUNT_POINT" 2>/dev/null; then
      echo "mounted via SPICE WebDAV at $MOUNT_POINT"; return 0
    fi
    echo "davfs2 couldn't mount $URL" >&2
    return 1
  fi

  echo "can't find any shared folder." >&2
  echo "In UTM: VM Settings → Sharing → pick a mode (VirtFS or SPICE WebDAV)," >&2
  echo "then power the VM off and back on." >&2
  return 1
}

case "${1:-}" in
  --umount|-u) sudo umount "$MOUNT_POINT" && echo "unmounted" ;;
  --status|-s) status ;;
  -h|--help)   sed -n '3,14p' "$0" | sed 's/^#\{0,2\} \{0,1\}//' ;;
  "")          mount_ ;;
  *)           echo "unknown option: $1" >&2; exit 1 ;;
esac
__PAYLOAD_PROVISION_SHARE_SH__
chmod +x "$W/provision/share.sh"

mkdir -p "$W/scripts"
cat > "$W/scripts/build.exp" <<'__PAYLOAD_SCRIPTS_BUILD_EXP__'
#!/usr/bin/expect -f
# Drives the build over the Alpine live serial console.
set timeout 900
log_user 1
match_max 400000

proc die {code msg} { puts "\n!! $msg"; exit $code }
proc wait_for {pat code msg {t 900}} {
    set timeout $t
    expect {
        -ex $pat {}
        timeout  { die $code "TIMEOUT: $msg" }
        eof      { die [expr {$code+40}] "unexpected EOF: $msg" }
    }
}

# write_payloads substitutes @OMARM_ROOT@ when deploying this file. If the
# marker is still there, it's running from a repository clone:
# in that case the root comes from OMARM_ROOT or the current directory.
set ROOT "@OMARM_ROOT@"
if {[string match "@*@" $ROOT]} {
  set ROOT [expr {[info exists env(OMARM_ROOT)] ? $env(OMARM_ROOT) : [pwd]}]
}
spawn -noecho $ROOT/scripts/qemu-build.sh

# --- Alpine live login (root, no password)
wait_for "localhost login:" 10 "Alpine live never reached the login prompt" 300
send "root\r"
wait_for "localhost:~#" 11 "no root shell in Alpine" 120

send "export PS1='RDY> '; echo TOK_SH_\$?\r"
wait_for "TOK_SH_0" 12 "failed to set the prompt" 60

# --- locate and mount the provisioning ISO
send "mkdir -p /media/prov; for d in /dev/vd? /dev/sr?; do mount -t iso9660 -o ro \$d /media/prov 2>/dev/null && \[ -f /media/prov/stage1.sh \] && break; umount /media/prov 2>/dev/null; done; ls /media/prov; echo TOK_PROV_\$?\r"
wait_for "TOK_PROV_0" 13 "provisioning ISO not found" 120

send "test -s /media/prov/alarm-rootfs.tgz; echo TOK_TGZ_\$?\r"
wait_for "TOK_TGZ_0" 14 "missing Arch Linux ARM rootfs on the ISO" 60

# --- full build (partitioning + chroot + packages + dotfiles)
set timeout -1
# stage1.sh emits the TOK_BUILD_<rc> token itself (piping through tee
# would mask the return code).
send "export DISK=/dev/vda; sh /media/prov/stage1.sh 2>&1 | tee /tmp/build.log\r"

expect {
    -ex "TOK_BUILD_0" {
        puts "\n\n==========================================="
        puts "   BUILD COMPLETE"
        puts "===========================================\n"
    }
    -re {TOK_BUILD_[1-9][0-9]*} {
        puts "\n\n!!!!!! BUILD FAILED !!!!!!\n"
        set timeout 300
        send "echo; echo ---- last 80 lines ----; tail -n 80 /tmp/build.log; echo TOK_TAIL_\$?\r"
        catch { wait_for "TOK_TAIL_" 15 "tail" 300 }
        exit 20
    }
    eof { die 16 "EOF during the build" }
}

# --- verification of the resulting disk
set timeout 600
send "mount -o subvol=@ /dev/vda2 /mnt 2>/dev/null || mount /dev/vda2 /mnt; mount /dev/vda1 /mnt/boot 2>/dev/null; echo '==== VERIFICATION ===='; echo '-- ESP --'; find /mnt/boot -maxdepth 3 | head -40; echo '-- kernel --'; ls -la /mnt/boot/Image* /mnt/boot/initramfs* 2>/dev/null; echo '-- user --'; ls -la /mnt/home/; echo '-- dotfiles --'; for h in /mnt/home/*/; do echo \"  \$h:\"; ls \"\$h/.config\" 2>/dev/null | tr '\\n' ' '; echo; done; echo; echo '-- hyprland --'; ls -la /mnt/usr/bin/Hyprland 2>/dev/null; echo TOK_VERIFY_\$?\r"
catch { wait_for "TOK_VERIFY_" 17 "verification" 600 }

send "sync; umount -R /mnt 2>/dev/null; poweroff -f\r"
expect eof
puts "\n===== BUILD VM POWERED OFF ====="
exit 0
__PAYLOAD_SCRIPTS_BUILD_EXP__
chmod +x "$W/scripts/build.exp"

mkdir -p "$W/scripts"
cat > "$W/scripts/repair.exp" <<'__PAYLOAD_SCRIPTS_REPAIR_EXP__'
#!/usr/bin/expect -f
# Usage: scripts/repair.exp <script-inside-the-ISO.sh>
# Boots Alpine with the disk already installed and runs that script in the chroot.
set timeout 900
log_user 1
match_max 400000
set FIX [lindex $argv 0]
if {$FIX eq ""} { puts "usage: repair.exp <fix.sh>"; exit 1 }

proc wait_for {pat code msg {t 900}} {
    set timeout $t
    expect { -ex $pat {} timeout { puts "\n!! TIMEOUT: $msg"; exit $code }
             eof { puts "\n!! EOF: $msg"; exit [expr {$code+40}] } }
}
# write_payloads substitutes @OMARM_ROOT@ when deploying this file. If the
# marker is still there, it means this is running from a clone of the repo:
# in that case the root comes from OMARM_ROOT or the current directory.
set ROOT "@OMARM_ROOT@"
if {[string match "@*@" $ROOT]} {
  set ROOT [expr {[info exists env(OMARM_ROOT)] ? $env(OMARM_ROOT) : [pwd]}]
}
spawn -noecho $ROOT/scripts/qemu-build.sh
wait_for "localhost login:" 10 "Alpine login" 300
send "root\r"
wait_for "localhost:~#" 11 "root shell" 120
send "export PS1='RDY> '; echo TOK_SH_\$?\r"
wait_for "TOK_SH_0" 12 "prompt" 60
send "mkdir -p /media/prov; for d in /dev/vd? /dev/sr?; do mount -t iso9660 -o ro \$d /media/prov 2>/dev/null && \[ -f /media/prov/repair.sh \] && break; umount /media/prov 2>/dev/null; done; ls /media/prov; echo TOK_PROV_\$?\r"
wait_for "TOK_PROV_0" 13 "provisioning ISO" 120

set timeout -1
send "export FIXSCRIPT=$FIX; sh /media/prov/repair.sh 2>&1 | tee /tmp/repair.log\r"
expect {
    -ex "TOK_REPAIR_0" { puts "\n\n===== REPAIR COMPLETE =====\n" }
    -re {TOK_REPAIR_[1-9][0-9]*} { puts "\n\n!!!!! REPAIR FAILED !!!!!\n"; exit 20 }
    eof { puts "\n!! EOF"; exit 16 }
}
set timeout 300
send "sync; poweroff -f\r"
expect eof
exit 0
__PAYLOAD_SCRIPTS_REPAIR_EXP__
chmod +x "$W/scripts/repair.exp"

mkdir -p "$W/scripts"
cat > "$W/scripts/qemu.sh" <<'__PAYLOAD_SCRIPTS_QEMU_SH__'
#!/bin/bash
# Build VM: NATIVE aarch64 with HVF (no emulation) on Apple Silicon.
# Alpine live boot over serial console + provisioning ISO carrying the ALARM rootfs.
set -e
# The root is set by write_payloads when this file is deployed.
ROOT=@OMARM_ROOT@
cd "$ROOT"
: "${VM_SMP:=8}"
: "${VM_MEM:=8192}"
FW=$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd
: "${PROV_ISO:=provision/provision.iso}"
: "${DISK_IMG:=vm/omarchy-arm.qcow2}"

[ -f vm/efi-vars.fd ] || dd if=/dev/zero of=vm/efi-vars.fd bs=1m count=64 status=none

exec qemu-system-aarch64 \
  -accel hvf -cpu host -smp "$VM_SMP" -m "$VM_MEM" \
  -M virt,highmem=on,gic-version=3 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$FW" \
  -drive if=pflash,format=raw,unit=1,file=vm/efi-vars.fd \
  -drive if=none,id=hd,file="$DISK_IMG",format=qcow2,cache=writeback,discard=unmap \
  -device virtio-blk-pci,drive=hd \
  -drive if=none,id=live,file=dl/alpine-virt-aarch64.iso,format=raw,media=cdrom,readonly=on \
  -device virtio-blk-pci,drive=live,bootindex=0 \
  -drive if=none,id=prov,file="$PROV_ISO",format=raw,media=cdrom,readonly=on \
  -device virtio-blk-pci,drive=prov \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci \
  -nographic

__PAYLOAD_SCRIPTS_QEMU_SH__
chmod +x "$W/scripts/qemu.sh"

mkdir -p "$W/scripts"
cat > "$W/scripts/make-utm.sh" <<'__PAYLOAD_SCRIPTS_MAKE-UTM_SH__'
#!/bin/bash
# Builds the .utm bundle by hand and registers it with UTM.
#
# UTM 4.7 only scans ~/Library/Containers/com.utmapp.UTM/Data/Documents/ once,
# at app launch (listRefresh() is called from ContentView.onAppear), so UTM
# has to be closed, the bundle written, and UTM reopened.
# config.plist requires all TEN top-level keys: they're decoded with
# decode(), not decodeIfPresent(), and omitting any of them makes UTM reject it.
set -euo pipefail

# The root is derived from the script's own location: this way the repo can
# be cloned anywhere without editing anything.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCS="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
NAME="${1:-Omarchy ARM}"
: "${DEST_DIR:=$DOCS}"
BUNDLE="$DEST_DIR/$NAME.utm"
: "${SRC_QCOW:=$ROOT/vm/omarchy-arm.qcow2}"
VARS_TPL=/Applications/UTM.app/Contents/Resources/qemu/edk2-arm-vars.fd
: "${UTM_CPUS:=8}"
: "${UTM_MEM:=8192}"

[ -f "$SRC_QCOW" ] || { echo "!! missing $SRC_QCOW"; exit 1; }
[ -f "$VARS_TPL" ] || { echo "!! missing UEFI NVRAM template $VARS_TPL"; exit 1; }

VM_UUID=$(uuidgen)
# Whoever receives the bundle reads these notes in UTM before booting: they
# have to state the real credentials, not the builder's.
NOTES_USER="${NOTES_USER:-omarchy}"
NOTES_PASS="${NOTES_PASS:-$NOTES_USER}"
# These two go inside XML. A '&' or '<' in the password used to break
# config.plist, and since `plutil -lint` runs at the end, the failure arrived
# AFTER copying the entire disk: nine gigabytes spent just to die with a
# message that never mentioned the password anywhere.
xmlq() { printf "%s" "${1-}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
NOTES_USER=$(xmlq "$NOTES_USER")
NOTES_PASS=$(xmlq "$NOTES_PASS")

DISK_UUID=$(uuidgen)
MAC=$(printf '02:%02X:%02X:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

# UTM only scans Documents when the app starts, so it has to be restarted for
# it to recognize the bundle. But force-quitting it takes down any VMs the
# user has running, so that's checked first.
if [ "$DEST_DIR" = "$DOCS" ] && pgrep -x UTM >/dev/null; then
  UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
  RUNNING=$("$UTMCTL" list 2>/dev/null | awk '$2=="started"{print $3" "$4}' | grep -v "^$" || true)
  if [ -n "$RUNNING" ]; then
    echo "==> VMs ARE RUNNING in UTM:"
    echo "$RUNNING" | sed 's/^/      /'
    echo "    Registering the bundle requires restarting UTM, which would kill them."
    if [ -t 0 ] && [ "${ASSUME_YES:-}" != "1" ]; then
      printf "    Close them and restart UTM? [y/N]: "
      read -r R </dev/tty || R=""
      case "$(printf '%s' "$R" | tr '[:upper:]' '[:lower:]')" in
        y|yes) : ;;
        *) echo "==> UTM will not be restarted: import the bundle manually via File → Import"; SKIP_RESTART=1 ;;
      esac
    else
      echo "==> unattended mode: UTM will NOT be closed. Import the bundle manually."
      SKIP_RESTART=1
    fi
  fi
  if [ "${SKIP_RESTART:-0}" != "1" ]; then
    echo "==> closing UTM so it rescans Documents"
    osascript -e 'quit app "UTM"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x UTM >/dev/null || break; sleep 1; done
    pgrep -x UTM >/dev/null && { pkill -x UTM || true; sleep 2; }
  fi
fi

echo "==> creating $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Data"
echo "    copying disk ($(du -h "$SRC_QCOW" | cut -f1))"
cp -c "$SRC_QCOW" "$BUNDLE/Data/$DISK_UUID.qcow2" 2>/dev/null || cp "$SRC_QCOW" "$BUNDLE/Data/$DISK_UUID.qcow2"
# The VARS half of the aarch64 UEFI uses the edk2-ARM-vars.fd template (not
# aarch64); UTM supplies edk2-aarch64-code.fd at runtime via -L.
install -m 0644 "$VARS_TPL" "$BUNDLE/Data/efi_vars.fd"

cat > "$BUNDLE/config.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Backend</key>
	<string>QEMU</string>
	<key>ConfigurationVersion</key>
	<integer>4</integer>
	<key>Information</key>
	<dict>
		<key>Name</key>
		<string>$NAME</string>
		<key>UUID</key>
		<string>$VM_UUID</string>
		<key>IconCustom</key>
		<false/>
		<key>Icon</key>
		<string>arch-linux</string>
		<key>Notes</key>
		<string>Arch Linux ARM (aarch64) + Hyprland + Omarchy 4 dotfiles.
User: ${NOTES_USER} · Password: ${NOTES_PASS} (also root). Change it with passwd.
The Option key (⌥) acts as SUPER. Read README.md.</string>
	</dict>
	<key>System</key>
	<dict>
		<key>Architecture</key>
		<string>aarch64</string>
		<key>Target</key>
		<string>virt</string>
		<key>CPU</key>
		<string>default</string>
		<key>CPUFlagsAdd</key>
		<array/>
		<key>CPUFlagsRemove</key>
		<array/>
		<key>CPUCount</key>
		<integer>$UTM_CPUS</integer>
		<key>ForceMulticore</key>
		<false/>
		<key>MemorySize</key>
		<integer>$UTM_MEM</integer>
		<key>JITCacheSize</key>
		<integer>0</integer>
	</dict>
	<key>QEMU</key>
	<dict>
		<key>DebugLog</key>
		<false/>
		<key>UEFIBoot</key>
		<true/>
		<key>RNGDevice</key>
		<true/>
		<key>BalloonDevice</key>
		<false/>
		<key>TPMDevice</key>
		<false/>
		<key>Hypervisor</key>
		<true/>
		<key>RTCLocalTime</key>
		<false/>
		<key>PS2Controller</key>
		<false/>
		<key>AdditionalArguments</key>
		<array/>
	</dict>
	<key>Input</key>
	<dict>
		<key>UsbBusSupport</key>
		<string>3.0</string>
		<key>UsbSharing</key>
		<false/>
		<key>MaximumUsbShare</key>
		<integer>3</integer>
	</dict>
	<key>Sharing</key>
	<dict>
		<key>DirectoryShareMode</key>
		<string>VirtFS</string>
		<key>DirectoryShareReadOnly</key>
		<false/>
		<key>ClipboardSharing</key>
		<true/>
	</dict>
	<key>Display</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>virtio-gpu-gl-pci</string>
			<key>DynamicResolution</key>
			<true/>
			<key>NativeResolution</key>
			<false/>
			<key>UpscalingFilter</key>
			<string>Nearest</string>
			<key>DownscalingFilter</key>
			<string>Linear</string>
		</dict>
	</array>
	<key>Drive</key>
	<array>
		<dict>
			<key>Identifier</key>
			<string>$DISK_UUID</string>
			<key>ImageName</key>
			<string>$DISK_UUID.qcow2</string>
			<key>ImageType</key>
			<string>Disk</string>
			<key>Interface</key>
			<string>VirtIO</string>
			<key>InterfaceVersion</key>
			<integer>1</integer>
			<key>ReadOnly</key>
			<false/>
		</dict>
	</array>
	<key>Network</key>
	<array>
		<dict>
			<key>Mode</key>
			<string>Shared</string>
			<key>Hardware</key>
			<string>virtio-net-pci</string>
			<key>MacAddress</key>
			<string>$MAC</string>
			<key>IsolateFromHost</key>
			<false/>
			<key>PortForward</key>
			<array/>
		</dict>
	</array>
	<key>Serial</key>
	<array>
		<dict>
			<key>Mode</key>
			<string>Ptty</string>
			<key>Target</key>
			<string>Auto</string>
		</dict>
	</array>
	<key>Sound</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>intel-hda</string>
		</dict>
	</array>
</dict>
</plist>
PLIST

echo "==> validating the plist"
plutil -lint "$BUNDLE/config.plist"
du -sh "$BUNDLE"
ls -la "$BUNDLE" "$BUNDLE/Data"

if [ "$DEST_DIR" = "$DOCS" ]; then
  echo "==> opening UTM so it registers the bundle"
  open -a UTM
  sleep 6
  /Applications/UTM.app/Contents/MacOS/utmctl list || true
else
  echo "==> bundle created outside UTM's folder (not registered)"
fi

echo ""
echo "Bundle:  $BUNDLE"
echo "UUID:    $VM_UUID"
echo "Start:   /Applications/UTM.app/Contents/MacOS/utmctl start \"$NAME\""
__PAYLOAD_SCRIPTS_MAKE-UTM_SH__
chmod +x "$W/scripts/make-utm.sh"
  # Every value is quoted: config.env is consumed with "source" and any of
  # them can carry spaces (VM_FULLNAME is the obvious case, but so can a
  # password or a VM name). Without quotes, the second word gets executed as
  # a command and the chroot dies with 127.
  # SINGLE quotes, not double. Double-quoting only solved the spaces: the
  # guest does `. config.env` and re-expands what's inside, so a password
  # with '$' or a backtick would arrive changed (or execute something). With
  # single quotes and ' escaped as '\'' the value travels literally.
  cfgq() { printf "%s" "${1-}" | sed "s/'/'\\\\''/g"; }
  cat > "$W/provision/config.env" <<CFGEOF
VM_USER='$(cfgq "$VM_USER")'
VM_PASSWORD='$(cfgq "$VM_PASSWORD")'
VM_FULLNAME='$(cfgq "$VM_FULLNAME")'
VM_EMAIL='$(cfgq "$VM_EMAIL")'
VM_HOSTNAME='$(cfgq "$VM_HOSTNAME")'
VM_TIMEZONE='$(cfgq "$VM_TIMEZONE")'
VM_KEYMAP='$(cfgq "$VM_KEYMAP")'
VM_XKB='$(cfgq "$VM_XKB")'
VM_LOCALE='$(cfgq "$VM_LOCALE")'
VM_LOCALE_EXTRA='$(cfgq "$VM_LOCALE_EXTRA")'
DISK='/dev/vda'
OMARCHY_REF='$(cfgq "$OMARCHY_REF")'
DIST_OLD_USER='$(cfgq "$VM_USER")'
DIST_NEW_USER='$(cfgq "$DIST_NEW_USER")'
WANT_TOOLS='$(cfgq "$WANT_TOOLS")'
WANT_EXTRAS='$(cfgq "$WANT_EXTRAS")'
CFGEOF
  # The harnesses carry the root as the @OMARM_ROOT@ marker, substituted on
  # deploy. It used to be the literal path of the Mac they were written on.
  sed -i '' "s#@OMARM_ROOT@#$W#g" \
    "$W/scripts/build.exp" "$W/scripts/repair.exp" "$W/scripts/qemu.sh" "$W/scripts/make-utm.sh" 2>/dev/null || true
  sed -i '' "s#scripts/qemu-build.sh#scripts/qemu.sh#g" "$W/scripts/build.exp" "$W/scripts/repair.exp" 2>/dev/null || true
  sed -i '' "s#^ROOT=.*#ROOT=$W#" "$W/scripts/qemu.sh" "$W/scripts/make-utm.sh" 2>/dev/null || true
}

make_iso() {  # make_iso <destination.iso> <file...>
  local out="$1"; shift
  local d; d=$(mktemp -d)
  cp "$@" "$d"/
  rm -f "$out"
  hdiutil makehybrid -iso -joliet -default-volume-name PROVISION -o "$out" "$d" >/dev/null
  rm -rf "$d"
}

# ─────────────────────────────── phase: build ───────────────────────────────
ph_build() {
  phase "build · disk build (headless, QEMU + HVF)"
  write_payloads
  # Short names: hdiutil truncates long ones in the ISO9660 tree
  make_iso "$W/provision/provision.iso" \
    "$W/provision/stage1.sh" "$W/provision/stage2.sh" "$W/provision/stage3.sh" \
    "$W/provision/config.env" "$W/provision/packages-core.txt" "$W/provision/packages-extra.txt"
  ln -f "$W/dl/alarm-rootfs.tgz" /tmp/alarm-rootfs.tgz 2>/dev/null || true
  # the rootfs travels inside the provisioning ISO
  local d; d=$(mktemp -d)
  cp "$W/provision"/{stage1.sh,stage2.sh,stage3.sh,config.env,packages-core.txt,packages-extra.txt} "$d"/
  cp "$W/provision"/{extras.sh,armsync.sh,clipbrd.sh,vdagent.py,share.sh} "$d"/
  ln "$W/dl/alarm-rootfs.tgz" "$d/alarm-rootfs.tgz" 2>/dev/null || cp "$W/dl/alarm-rootfs.tgz" "$d/"
  rm -f "$W/provision/provision.iso"
  hdiutil makehybrid -iso -joliet -default-volume-name PROVISION -o "$W/provision/provision.iso" "$d" >/dev/null
  rm -rf "$d"
  ok "provisioning ISO $(du -h "$W/provision/provision.iso" | cut -f1)"

  # Rebuilding discards the previous disk, which is ~40 min of work. If one
  # exists and the session is interactive, it asks; otherwise a copy is kept.
  if [[ -s $W/vm/omarchy-arm.qcow2 ]]; then
    if confirm "A built disk already exists ($(du -h "$W/vm/omarchy-arm.qcow2" | cut -f1)). Discard it and rebuild?" no; then
      rm -f "$W/vm/omarchy-arm.qcow2"
    else
      mv "$W/vm/omarchy-arm.qcow2" "$W/vm/omarchy-arm.qcow2.previous"
      info "the previous one is kept at $W/vm/omarchy-arm.qcow2.previous"
    fi
  fi
  rm -f "$W/vm/efi-vars.fd"
  qemu-img create -f qcow2 "$W/vm/omarchy-arm.qcow2" "$DISK_SIZE" >/dev/null
  dd if=/dev/zero of="$W/vm/efi-vars.fd" bs=1m count=64 status=none

  info "starting the builder (Alpine live → chroot → 3 stages)"
  info "this takes ~40 min depending on the network; full log at $W/logs/build.log"
  VM_SMP=$BUILD_SMP VM_MEM=$BUILD_MEM PROV_ISO="$W/provision/provision.iso" \
    expect -f "$W/scripts/build.exp" > "$W/logs/build.log" 2>&1
  local rc=$?
  # stage2 emits TOK_STAGE3_<rc>: without checking it, a stage3 that fails
  # entirely (no dotfiles, no tools, no theme) would pass as a correct build.
  if grep -qa "TOK_STAGE3_" "$W/logs/build.log" && ! grep -qa "TOK_STAGE3_0" "$W/logs/build.log"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/build.log" | grep -aE "^(!!|==>)" | tail -25
    die "stage3 failed: the disk exists but doesn't have the Omarchy configuration. Log: $W/logs/build.log"
  fi
  grep -qa "TOK_BUILD_0" "$W/logs/build.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/build.log" | tail -40
    die "the build failed (rc=$rc); check $W/logs/build.log"
  }
  ok "disk built: $(du -h "$W/vm/omarchy-arm.qcow2" | cut -f1)"
}

# ──────────────────────────────── phase: utm ────────────────────────────────
ph_utm() {
  phase "utm · .utm bundle"
  write_payloads
  [[ -s $W/vm/omarchy-arm.qcow2 ]] || die "no built disk; run the build phase"
  # Deleting a same-named VM destroys its disk. If one already exists, it
  # asks; without a terminal it picks another name instead of destroying anything.
  if "$UTMCTL" list 2>/dev/null | grep -q "  $VM_NAME$"; then
    if confirm "A VM named '$VM_NAME' already exists in UTM. Delete it and replace it?" no; then
      "$UTMCTL" delete "$VM_NAME" >/dev/null 2>&1 || true; sleep 2
    else
      VM_NAME="$VM_NAME $(date +%H%M)"
      info "will be registered as '$VM_NAME'"
    fi
  fi
  local ulog="$W/logs/make-utm.log"
  if ! SRC_QCOW="$W/vm/omarchy-arm.qcow2" UTM_CPUS=$UTM_CPUS UTM_MEM=$UTM_MEM \
       NOTES_USER="$VM_USER" NOTES_PASS="$VM_PASSWORD" ASSUME_YES="${ASSUME_YES:-}" \
       bash "$W/scripts/make-utm.sh" "$VM_NAME" > "$ulog" 2>&1; then
    tail -20 "$ulog"
    die "make-utm.sh failed; full log at $ulog"
  fi
  tail -4 "$ulog"
  [[ -f "$DOCS/$VM_NAME.utm/config.plist" ]] || die "the bundle didn't end up in $DOCS"
  ok "bundle created at $DOCS/$VM_NAME.utm"
}

# ─────────────────────────────── phase: verify ──────────────────────────────
ph_verify() {
  phase "verify · boot and check"
  "$UTMCTL" start "$VM_NAME" >/dev/null 2>&1 || true
  info "waiting for boot..."
  sleep 60
  local pty; pty=$("$UTMCTL" attach "$VM_NAME" 2>&1 | grep -o '/dev/ttys[0-9]*' | head -1)
  # This used to be "warn + return 0": without a serial port there's no way
  # to verify, and continuing to sanitize/package would package up an image
  # nobody has looked at. If you really want to skip it: --from sanitize.
  [[ -n $pty ]] || die "couldn't open the serial port for '$VM_NAME'; without it there's no way to verify (to continue anyway: --from sanitize)"
  # This phase used to collect metrics and never compare them against
  # anything, so it always ended in "ok" no matter what. Now the guest emits a verdict
  # and the host checks it. Six conditions, all required:
  #   H  Hyprland alive
  #   Q  quickshell alive (if it were waybar, it'd be Omarchy 3)
  #   B  >=400 omarchy-* commands in /usr/bin (counted by name, not by
  #      directory total: /usr/bin has ~2900 system files and
  #      "ls | wc -l" would pass any threshold even with zero of them)
  #   R  <=5 broken symlinks (one is from qt6-webengine, unrelated to this)
  #   U  >=6 user units installed: without them first-run loops forever
  #   V  the tree's version starts with 4
  # The previous threshold looked at /usr/local/bin, where the commands no
  # longer live: a guaranteed false positive as soon as they moved to /usr/bin.
  local vlog="$W/logs/verify.log"
  # The heredoc is QUOTED. Without quotes, the host's bash expands the
  # $(...) before expect ever sees them, and the checks run on the Mac
  # instead of inside the VM (pgrep with BSD syntax, no systemctl at all).
  # The three values that are needed come in through the environment and are
  # read with $env(...), which is Tcl's, not bash's.
  PTY="$pty" GUSER="$VM_USER" GPASS="$VM_PASSWORD" \
  expect > "$vlog" 2>&1 <<'EXPEOF'
set timeout 180
log_user 1
set fd [open $env(PTY) w+]
fconfigure $fd -mode 115200,n,8,1 -translation binary -buffering none
spawn -open $fd
send "\r"
sleep 2
expect {
  -re {login:} { send "$env(GUSER)\r"; expect -re {[Pp]assword:}; send "$env(GPASS)\r"; sleep 5 }
  -re {\$ $} {}
  -re {❯} {}
  timeout {}
}
# NOTE: no `ls` here. Omarchy aliases ls to eza in long format, and the alias
# is live because this runs in an interactive shell over the serial console.
# With long format the line starts with the permissions, so `grep '^omarchy-'`
# counts zero and verify declares a perfectly good image KO. find isn't
# aliased and doesn't depend on the output format either.
# KNOWN LIMIT: this validates the FIRST boot. A failure that only showed up
# on reboot -like the one fixes/19 patches on older images, where the
# official agent used to come back from autostart.lua- wouldn't be caught
# here. It was manually confirmed that the current image does survive a
# reboot: the agent starts with the graphical session. That's why a second
# pass is NOT added, which would be a fixed cost on every build against a
# hypothesis. If a failure of that kind ever reappears, this is the place to
# reboot and repeat the verdict.
#
# NOTE 2: the token is SPLIT (VER\"DICT_OK\"). The serial console echoes
# the command, so if the token traveled whole the log would contain the
# string VERDICT_OK before the guest answered anything, and the host's
# `grep` would find it there: the phase would say OK no matter what. Split,
# the echo shows VER"DICT_OK" and only the real response matches.
#
# C counts the five known ways the clipboard can die. None needs a connected
# SPICE client, so it can be checked here.
send "H=\$(pgrep -c Hyprland); Q=\$(pgrep -c quickshell); B=\$(find /usr/bin -maxdepth 1 -name 'omarchy-*' | wc -l); R=\$(find /usr/bin /usr/local/bin -xtype l | wc -l); U=\$(find /usr/lib/systemd/user -maxdepth 1 -name 'omarchy-*.service' | wc -l); V=\$(cat /usr/share/omarchy/version 2>/dev/null | cut -d. -f1); C=0; test -x /usr/local/bin/omarchy-arm-vdagent && C=\$((C+1)); grep -qs -- ' -X ' /etc/systemd/system/spice-vdagentd.service.d/override.conf && C=\$((C+1)); systemctl is-active --quiet spice-vdagentd && C=\$((C+1)); systemctl --user is-active --quiet omarchy-arm-vdagent.service && C=\$((C+1)); grep -vs -- '^\[\[:space:]]*--' ~/.config/hypr/autostart.lua | grep -qs spice-vdagent || C=\$((C+1)); echo \"### H=\$H Q=\$Q BINS=\$B BROKEN=\$R UNITS=\$U VER=\$V CLIP=\$C/5\"; if \[ \$H -ge 1 ] && \[ \$Q -ge 1 ] && \[ \$B -ge 400 ] && \[ \$R -le 5 ] && \[ \$U -ge 6 ] && \[ \"\$V\" = 4 ] && \[ \$C -eq 5 ]; then echo VER\"DICT_OK\"; else echo VER\"DICT_KO\"; fi\r"
expect { -re {VERDICT_(OK|KO)} {} timeout {} }
EXPEOF
  sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | grep -aE "^###" | tail -1
  if grep -qa "^VERDICT_OK" "$vlog"; then
    ok "VM '$VM_NAME' verified: Omarchy 4, Hyprland + quickshell alive, commands and units in place, clipboard working"
  elif grep -qa "^VERDICT_KO" "$vlog"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | tail -20
    die "the VM boots but the desktop isn't complete; log at $vlog"
  else
    # This can't be a warning either: if the guest doesn't answer, nothing is
    # known about the image, and the next step would be packaging and
    # distributing it.
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$vlog" | tail -20
    die "the guest didn't emit a verdict over the serial port; log at $vlog"
  fi
}

# ────────────────────────────── phase: sanitize ─────────────────────────────
ph_sanitize() {
  phase "sanitize · clean copy for distribution"
  write_payloads
  "$UTMCTL" stop "$VM_NAME" >/dev/null 2>&1 || true
  while [[ $("$UTMCTL" status "$VM_NAME" 2>/dev/null) == started ]]; do sleep 3; done

  local src; src=$(find "$DOCS/$VM_NAME.utm/Data" -name '*.qcow2' | head -1)
  [[ -s $src ]] || src="$W/vm/omarchy-arm.qcow2"
  rm -f "$W/dist/dist.qcow2"
  cp -c "$src" "$W/dist/dist.qcow2" 2>/dev/null || cp "$src" "$W/dist/dist.qcow2"
  ok "working copy made (the original VM is untouched)"

  make_iso "$W/provision/repair.iso" "$W/provision/repair.sh" "$W/provision/sanitize.sh" \
           "$W/provision/config.env" "$W/provision/extras.sh" "$W/provision/armsync.sh"
  info "cleaning (generic user, no keys or identity)..."
  PROV_ISO="$W/provision/repair.iso" DISK_IMG="$W/dist/dist.qcow2" \
  DIST_OLD_USER="$VM_USER" DIST_NEW_USER="$DIST_NEW_USER" \
    expect -f "$W/scripts/repair.exp" sanitize.sh > "$W/logs/sanitize.log" 2>&1
  # TOK_REPAIR_0 only says the chroot didn't blow up, and sanitize.sh runs
  # without -e: it would return 0 even if usermod had failed and the image
  # kept the builder's user. The token that actually means something is
  # SANITIZE_OK, which sanitize.sh now only prints if its invariants hold.
  if grep -qa "SANITIZE_FAILED" "$W/logs/sanitize.log"; then
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | grep -aE "✗|SANITIZE_FAILED" | tail -20
    die "the image failed the distribution invariants; check $W/logs/sanitize.log"
  fi
  grep -qa "SANITIZE_OK" "$W/logs/sanitize.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | tail -30
    die "cleanup didn't reach the end; check $W/logs/sanitize.log"
  }
  grep -qa "TOK_REPAIR_0" "$W/logs/sanitize.log" || {
    sed 's/\x1b\[[0-9;?=]*[a-zA-Z]//g' "$W/logs/sanitize.log" | tail -30
    die "cleanup failed; check $W/logs/sanitize.log"
  }
  ok "image sanitized, distribution invariants checked"
}

# ────────────────────────────── phase: package ──────────────────────────────
ph_package() {
  phase "package · compact and compress"
  [[ -s $W/dist/dist.qcow2 ]] || die "no sanitized image; run the sanitize phase"
  info "compacting and compressing the qcow2 clusters..."
  rm -f "$W/dist/slim.qcow2"
  # -c compresses inside the qcow2 itself: the image takes up half as much
  # even once decompressed on the recipient's disk. It decompresses on read.
  qemu-img convert -c -O qcow2 "$W/dist/dist.qcow2" "$W/dist/slim.qcow2" || die "qemu-img convert failed"
  qemu-img check "$W/dist/slim.qcow2" >/dev/null || die "the compacted image doesn't validate"
  ok "$(du -h "$W/dist/dist.qcow2" | cut -f1) → $(du -h "$W/dist/slim.qcow2" | cut -f1)"

  # The bundle that ships does NOT carry $VM_NAME. That name is the builder's
  # and can be anything ("Omarchy ARM v5" in one of the batches), and it used
  # to travel inside the zip as the directory name and as <key>Name</key>, so
  # importing it into UTM would show the internal versioning of whoever built it.
  # The README also used to say "double-click Omarchy ARM.utm", which didn't exist yet.
  local DNAME="${DIST_VM_NAME:-Omarchy ARM}"
  rm -rf "$W/dist/$DNAME.utm"
  SRC_QCOW="$W/dist/slim.qcow2" DEST_DIR="$W/dist" UTM_CPUS=$UTM_CPUS UTM_MEM=$UTM_MEM \
    NOTES_USER="$DIST_NEW_USER" NOTES_PASS="$DIST_NEW_USER" \
    bash "$W/scripts/make-utm.sh" "$DNAME" >/dev/null \
    || die "couldn't create the distributable bundle"
  # Last net: neither the plist nor the bundle's NAME must carry any trace of
  # the user or the builder's working name.
  if grep -q "\b$VM_USER\b" "$W/dist/$DNAME.utm/config.plist" 2>/dev/null; then
    die "the bundle's config.plist mentions '$VM_USER'; check make-utm.sh"
  fi
  if [[ "$DNAME" != "$(printf '%s' "$DNAME" | tr -cd 'A-Za-z .-')" ]]; then
    die "distribution name '$DNAME' has unusual characters; use something neutral"
  fi
  write_readme "$W/dist/README.md"

  info "compressing..."
  ( cd "$W/dist" && rm -f omarchy-arm-utm.zip \
      && zip -r -q -1 omarchy-arm-utm.zip "$DNAME.utm" README.md \
      && shasum -a 256 omarchy-arm-utm.zip > omarchy-arm-utm.zip.sha256 )
  rm -f "$W/dist/dist.qcow2" "$W/dist/slim.qcow2"
  ok "done: $W/dist/omarchy-arm-utm.zip ($(du -h "$W/dist/omarchy-arm-utm.zip" | cut -f1))"
  cat "$W/dist/omarchy-arm-utm.zip.sha256"
}

write_readme() {
  # The text lives in provision/src/README.md and gets embedded as-is
  # (scripts/sync re-embeds it). When these were two hand-maintained copies,
  # the script's copy fell behind and shipped inside the zip claiming false
  # things -- 432 commands when there were 439, "the zip is 7 GB" when it was
  # 3.6 -- and even carried an internal note meant only for the maintainer.
  cat > "$1" <<'__PAYLOAD_LEEME_MD__'
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
__PAYLOAD_LEEME_MD__
}

# ──────────────────────────────────── questions ────────────────────────────
# Only what's genuinely a decision and costly to get wrong is asked. Everything
# else (Alpine version, rootfs URL, Omarchy branch, disk size, locales) stays
# an environment variable: those are implementation details, not decisions.
# Uses ':=' so they can be set from the environment too, like the rest:
#   WANT_EXTRAS=no ./build-omarchy-arm.sh --yes
: "${WANT_TOOLS:=yes}"
: "${WANT_EXTRAS:=yes}"
: "${WANT_DIST:=yes}"

questionnaire() {
  detect_from_host
  if (( ! INTERACTIVE )); then
    # No terminal: the historical behavior, fully automatic. Still saved, so
    # a later --from doesn't start with different values. But if there were
    # already answers from an earlier run, they aren't overwritten: a
    # bounced `--yes` used to destroy what the user had answered by hand.
    [[ -f "$W/answers.env" ]] || save_answers
    return
  fi
  phase "configuration"
  info "Enter accepts the value in brackets. Detected from your Mac."
  echo

  ask VM_TIMEZONE "Timezone"                         "$VM_TIMEZONE"
  ask VM_KEYMAP   "Keyboard (console)"               "$VM_KEYMAP"
  ask VM_XKB      "Keyboard (Hyprland/Wayland)"      "$VM_XKB"
  echo
  ask UTM_CPUS    "Cores for the VM"                 "$UTM_CPUS"
  ask UTM_MEM     "Memory for the VM (MiB)"          "$UTM_MEM"
  ask DISK_SIZE   "Disk size"                        "$DISK_SIZE"
  echo

  # ~40 min of compiling. Without them the desktop still works, but the
  # screensaver, screenshot annotator and calculator, among others, are missing.
  if confirm "Compile the 17 Omarchy tools that don't exist for ARM (~40 min)?" yes; then
    WANT_TOOLS=yes
  else
    WANT_TOOLS=no
    warn "without them, ttfx, tensaku, omacalc, omacut, omawrite, aether, cliamp... will be missing"
  fi
  echo

  # OBS and Pinta are the most expensive part of the build. They're included
  # because they're free software and the distributed image carries them, but
  # for a test VM they're unnecessary.
  if confirm "Include OBS Studio and Pinta (free software, they compile: ~45 min)?" yes; then
    WANT_EXTRAS=yes
  else
    WANT_EXTRAS=no
    info "they can be added later from inside: omarchy-arm-extras pinta obs"
  fi
  echo

  # The distinction that changes the outcome the most: an image to distribute
  # versus a VM for your own use.
  info "Two possible uses:"
  info "  · image to distribute  → renames the user to '$DIST_NEW_USER', deletes"
  info "    SSH keys and identity, and produces a ~6.5 GB zip (~30 min extra)"
  info "  · VM for you           → stays as-is, with user '$VM_USER'"
  if confirm "Prepare the image for distribution?" no; then
    WANT_DIST=yes
    ask DIST_NEW_USER "User for the distributable image" "$DIST_NEW_USER"
  else
    WANT_DIST=no
    ask VM_USER     "VM user"          "$VM_USER"
    ask VM_PASSWORD "Password"         "$VM_PASSWORD"
    ask VM_FULLNAME "Full name"        "$VM_FULLNAME"
  fi
  echo
  info "summary: $VM_KEYMAP/$VM_XKB · $VM_TIMEZONE · ${UTM_CPUS} cores · ${UTM_MEM} MiB · disk $DISK_SIZE"
  info "         tools: $WANT_TOOLS · OBS+Pinta: $WANT_EXTRAS · distribute: $WANT_DIST"
  confirm "Start?" yes || die "cancelled"
  save_answers
}

# ──────────────────────────────────── main ─────────────────────────────────
# Prints the whole header, whatever its length: hardcoding '2,30p' meant
# --help would lose the phase list every time the banner grew.
usage() { awk 'NR>1 && /^#/{print; next} NR>1{exit}' "$0" | sed 's/^#\{0,2\} \{0,1\}//'; }

run_from=""; run_only=""
while (($#)); do
  case "$1" in
    # ${2:-} rather than $2: with `set -u` a missing argument aborts with
    # "unbound variable" and a line number, instead of the useful message below.
    --from) run_from="${2:-}"; [[ -n $run_from ]] || { usage; die "--from needs a phase (${PHASES[*]})"; }; shift 2 ;;
    --only) run_only="${2:-}"; [[ -n $run_only ]] || { usage; die "--only needs a phase (${PHASES[*]})"; }; shift 2 ;;
    --list) printf '%s\n' "${PHASES[@]}"; exit 0 ;;
    --yes|-y) ASSUME_YES=1; INTERACTIVE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# The build user's name ends up in a `find ... -regex` in sanitize and in
# paths throughout the guest. An unusual or too-short name turns that sweep
# into a shotgun: it's required to be a real username and not a substring of
# the distributable image's user.
[[ $VM_USER =~ ^[a-z_][a-z0-9_-]{2,31}$ ]] \
  || die "VM_USER='$VM_USER' is invalid: lowercase, digits, '-' and '_', starting with a letter, 3-32 characters"
[[ $DIST_NEW_USER == *"$VM_USER"* ]] \
  && die "VM_USER='$VM_USER' is part of DIST_NEW_USER='$DIST_NEW_USER'; pick another"

# Combining the two runs nothing: if the --only phase comes BEFORE the --from
# one in the array, the loop never sets started=1 and the script used to
# announce "Done in 0 min." with rc=0 without doing anything at all. They're
# mutually exclusive, so it's enforced outright.
[[ -n $run_from && -n $run_only ]] && die "--from and --only are mutually exclusive: pick one"

# A misspelled phase name must not exit successfully without doing anything.
for sel in "$run_from" "$run_only"; do
  [[ -z $sel ]] && continue
  printf '%s\n' "${PHASES[@]}" | grep -qxF "$sel" \
    || die "unknown phase: '$sel' (valid: ${PHASES[*]})"
done

# Resuming or running a single phase must not reopen the questionnaire, but
# it MUST recover what was answered last time.
if [[ -z $run_from && -z $run_only ]]; then
  load_answers          # what was already answered becomes the default
  questionnaire
else
  load_answers || true
  if [[ -f "$W/answers.env" ]]; then
    info "resuming with the answers from $W/answers.env (user '$VM_USER', distribute: ${WANT_DIST:-no})"
  else
    warn "no $W/answers.env: defaults will be used, which may not be what you chose"
  fi
fi

# Where phases get trimmed is decided HERE: after the questionnaire and
# loading the answers, with the final value of WANT_DIST, and never when the
# user has named sanitize or package by hand -- that would mean doing nothing
# and exiting successfully, exactly what was just removed in two other places.
if [[ ${WANT_DIST:-yes} == no \
      && $run_from != sanitize && $run_from != package \
      && $run_only != sanitize && $run_only != package ]]; then
  PHASES=(deps fetch prepare build utm verify)
fi

started=0
[[ -z $run_from ]] && started=1
t0=$SECONDS
for p in "${PHASES[@]}"; do
  [[ -n $run_only && $p != "$run_only" ]] && continue
  [[ -n $run_from && $p == "$run_from" ]] && started=1
  (( started )) || continue
  ensure_dirs
  "ph_$p" || die "phase '$p' failed"
done
echo
echo "${c_ok}Done in $(( (SECONDS-t0)/60 )) min.${c_off}"
