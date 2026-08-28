#!/bin/bash
#
#  omarchy-arm-extras — installs Arch Linux ARM apps that aren't in the image
#  ───────────────────────────────────────────────────────────────────────────
#  Proprietary apps are deliberately NOT bundled in: packaging them into a
#  .zip for distribution would mean redistributing third-party binaries. This
#  script downloads them from their OFFICIAL source, on your machine, at your
#  own discretion.
#
#  Almost all of them have an official arm64 build. The ones already included
#  in the image (free software) are marked [already installed] and skipped.
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
# space partway through. We work on real disk instead.
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-arm-extras"
OK_LIST=(); KO_LIST=()

# ── catalog ─────────────────────────────────────────────────────────────────
#  key|title|description
CATALOG=(
  "1password|1Password|Password manager. Official arm64 tarball from AgileBits"
  "1password-cli|1Password CLI|The op command. Official arm64 static binary"
  "obsidian|Obsidian|Markdown notes. Official arm64 AppImage"
  "typora|Typora|WYSIWYG markdown editor. Official arm64 package via AUR"
  "localsend|LocalSend|Send files between devices. Official arm64 build"
  "chrome|Google Chrome|Brings Widevine for arm64: enables Spotify and Netflix web"
  "spotify-web|Spotify (webapp)|Launcher for open.spotify.com + remaps SUPER+SHIFT+M"
  "pinta|Pinta|Image editor. Built with Microsoft's arm64 .NET"
  "obs|OBS Studio|Capture and streaming. Built without the browser plugin"
)

catalog_keys()  { printf '%s\n' "${CATALOG[@]}" | cut -d'|' -f1; }
catalog_title() { printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" '$1==k{print $2}'; }
catalog_desc()  { printf '%s\n' "${CATALOG[@]}" | awk -F'|' -v k="$1" '$1==k{print $3}'; }

# ── utilities ───────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# Pinta and OBS Studio are free software and ship inside the image; everything
# else doesn't. Without this check, `--all` would recompile all of OBS (half
# an hour) just to reinstall what's already there.
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
  info "sudo is needed to install packages."
  sudo -v || { fail "no privileges"; return 1; }
}

# Builds an AUR package while working around the usual ARM pitfalls:
#  · the clone URL uses the PackageBase, which isn't always the same as the name
#  · many PKGBUILDs default to arch=(x86_64), not because of real incompatibility
#  · a PKGBUILD can produce several subpackages, and only one may have the broken dependency
aur_build() {
  # A single `local` expands ALL values before assigning any of them, so $pkg
  # wouldn't exist yet when building $dir, and with set -u the script aborts.
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
  # isn't in the keyring, makepkg aborts. We import the ones the PKGBUILD
  # itself declares, instead of skipping verification.
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
    info "patched arch= to include aarch64"
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
  info "${c_dim}On Hyprland it's best launched with --ozone-platform=wayland${c_off}"
}

do_1password_cli() { title "1Password CLI"; aur_build 1password-cli && ok "$(op --version 2>/dev/null)"; }

do_obsidian() {
  title "Obsidian"
  info "There's an official arm64 AppImage and tarball. We use the tarball: it doesn't depend on fuse2."
  # WATCH OUT: releases/latest can be an Android-ONLY release (a lone .apk).
  # We need to find the latest one that actually publishes the arm64 desktop tarball.
  local url
  url=$(curl -fsSL --max-time 30 "https://api.github.com/repos/obsidianmd/obsidian-releases/releases?per_page=15" \
        | grep -oE '"browser_download_url": *"[^"]*obsidian-[0-9.]+-arm64\.tar\.gz"' \
        | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
  [ -n "$url" ] || { fail "couldn't find any arm64 tarball in the latest releases"; return 1; }
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
  ok "Obsidian installed to /opt/obsidian ($(basename "$url"))"
}

do_typora() {
  title "Typora"
  info "The AUR package 'typora' pulls the official arm64 .deb. Don't use typora-electron: it needs electron42, which doesn't exist on ARM."
  aur_build typora && ok "$(pacman -Q typora)"
}

do_localsend() { title "LocalSend"; aur_build localsend-bin localsend-bin && ok "$(pacman -Q localsend-bin)"; }

do_chrome() {
  title "Google Chrome"
  info "Chrome arm64 includes Widevine (the DRM that Spotify and Netflix web require)."
  info "The Chromium from the repos does NOT include it, and the chromium-widevine package is x86_64 only."
  aur_build google-chrome || return 1
  ok "$(pacman -Q google-chrome)"
  info "${c_dim}Check the DRM at chrome://components → 'Widevine Content Decryption Module'${c_off}"
}

do_spotify_web() {
  title "Spotify (webapp)"
  # Omarchy treats Spotify as a native package, not a webapp — and that package
  # is x86_64. On ARM the path that works is the web version, which needs Widevine.
  if ! have google-chrome-stable; then
    warn "without Google Chrome the Spotify web player won't play: install 'chrome' first"
  fi
  if have omarchy-webapp-install; then
    omarchy-webapp-install "Spotify" "https://open.spotify.com" \
      "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/spotify.png" \
      "$(have google-chrome-stable && echo 'google-chrome-stable --app=https://open.spotify.com')" \
      >/dev/null 2>&1 && ok "launcher created in the applications menu"
  else
    warn "omarchy-webapp-install isn't available"
  fi
  # Remap SUPER+SHIFT+M, which in Omarchy points to the native binary
  local f="$HOME/.config/hypr/bindings.lua"
  if [ -f "$f" ] && ! grep -q "open.spotify.com" "$f"; then
    cat >> "$f" <<'LUA'

-- Spotify has no native client for aarch64: SUPER+SHIFT+M opens the webapp.
-- Needs Google Chrome, which is what brings Widevine on arm64.
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
  warn "stays outside the update manager: every new version has to be repeated by hand"
}

do_obs() {
  title "OBS Studio"
  info "OBS builds fine on aarch64. The only thing blocking it on Arch Linux ARM is the"
  info "browser subpackage, whose 'cef' only exists for x86_64. It's disabled."
  warn "building Qt6 + OBS inside the VM takes a good while"
  local dir="$WORK/obs-studio"
  rm -rf "$dir"; mkdir -p "$WORK"
  git clone -q --depth 1 https://gitlab.archlinux.org/archlinux/packaging/packages/obs-studio.git "$dir" \
    || { fail "couldn't clone Arch's PKGBUILD"; return 1; }
  cd "$dir" || return 1
  sed -i "s/^arch=(\(.*\))/arch=(\1 'aarch64')/" PKGBUILD
  # WATCH OUT: 'cef' is on the SAME line as makedepends=, not its own line, so
  # it has to be removed as a token, not as a whole line.
  sed -i "s/'cef'[[:space:]]*//g" PKGBUILD
  sed -i "/cef_api_versions\.h/d; /-DCEF_API_VERSION/d; /_cef_api_version/d" PKGBUILD
  sed -i 's/-DENABLE_BROWSER=ON/-DENABLE_BROWSER=OFF/' PKGBUILD
  # package_obs-studio() moves the browser plugin's files into the separate
  # subpackage. Without the browser those files don't exist and the `mv` aborts
  # packaging AFTER everything has already built: those two lines have to go.
  sed -i '/mv \$pkgdir\/usr\/lib\/obs-plugins\/{obs-browser-page,obs-browser.so}/d' PKGBUILD
  sed -i '/mv \$pkgdir\/usr\/share\/obs\/obs-plugins\/obs-browser /d' PKGBUILD
  # and the plugin's patches, which no longer apply to anything
  sed -i '/patch -d plugins\/obs-browser/d' PKGBUILD
  # source=() and sha256sums=() are left untouched: removing entries from one
  # without the other makes makepkg abort with "Integrity checks differ in size
  # from the source array". Downloading obs-browser needlessly only costs bandwidth.
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
    ok "already included in this image (--force to reinstall)"
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
    *) fail "unknown key '$k'"; return 1 ;;
  esac
}

show_list() {
  echo
  echo "${c_hi}Apps installed from their official source${c_off}"
  echo "${c_dim}Proprietary apps aren't bundled in on purpose: redistributing their binaries"
  echo "in an image that gets shared would be problematic. Here they're downloaded to"
  echo "your machine, from the vendor's site.${c_off}"
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
  # The work directory isn't removed: it holds the build.log files, the only
  # way to figure out why something failed.
  info "logs in $WORK/<package>/build.log"
else
  rm -rf "$WORK"
fi
echo
