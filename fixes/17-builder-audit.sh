#!/bin/bash
# 17 · The 37 defects found by the builder audit
#
# This isn't a script meant to run: it's a record of what was fixed in
# build-omarchy-arm.sh and provision/src/* after auditing it against its
# own sources of truth (the 16 previous fixes and the findings from the
# article), with an independent refuter for each finding.
#
# BLOCKERS
#  1. sanitize.sh deleted /root/prov in step 7 and read it in steps 8a/8b:
#     the image shipped without the post-update hook or omarchy-arm-extras,
#     silently. The deletion is now done by repair.sh on exiting the chroot.
#  2. stage3 runs as a regular user and /root is 0750: its guards
#     [ -f /root/prov/... ] silently returned false. stage2 now leaves a
#     copy in ~/.omarchy-arm-prov.
#  3. DIST_OLD_USER/DIST_NEW_USER were exported on the host and never made
#     it into the guest: sanitize always renamed the literal "gabriel". Now
#     they travel in config.env and sanitize aborts if the user doesn't exist.
#  4. A total stage3 failure was downgraded to a warn and the build was
#     declared successful. stage2 now emits TOK_STAGE3_<rc> and ph_build
#     checks it.
#  5. The config.plist in the distributable bundle advertised "User:
#     gabriel / gabriel": false, and a leak. Now parameterized and checked
#     in ph_package.
#  6. ph_utm deleted any UTM VM with the same name without asking.
#  7. make-utm.sh killed the entire UTM application, along with the user's
#     VMs inside it.
#  8. ALPINE_ISO pinned to 3.24.1, which Alpine removes from the CDN once
#     the next patch ships. Now it resolves the latest and verifies its
#     sha256.
#  9. OMARCHY_REF=quattro with no fallback: if the branch disappears,
#     prepare dies without explaining why. Now it falls back to the
#     default branch with a warning.
#
# SERIOUS (selection)
#  · ph_verify collected metrics and never compared them: it could never fail.
#  · ph_utm swallowed make-utm.sh's error with "| tail -4".
#  · ph_fetch announced "MD5 verified" even when the checksum's curl failed.
#  · ph_package didn't use -c: it didn't reproduce the compressed image
#    that shipped.
#  · write_readme() generated a 17-line README with two false claims. Now
#    dist/README.md is embedded as-is.
#  · The build loop had lost makepkg's -s flag: with no build dependencies,
#    most PKGBUILDs fail at the first step.
#  · Fix 15 (trimmed down) hadn't been folded in anywhere.
#  · ph_build destroyed the previous disk (40 min of work) without warning.
#
# MINOR (selection)
#  · The $TERMINAL fallback pointed to alacritty, which quattro doesn't
#    install (foot).
#  · spice-vdagentd was never enabled: no shared clipboard.
#  · Four steps from fix 01 were missing: /etc/gnupg, systemd-oomd,
#    NetworkManager-wait-online, and the gnome-keyring PAM entry in SDDM.
#  · /root/STAGE2_OK and the randomness seed were shipping inside the image.
#  · build.exp checked the dotfiles at /mnt/home/gabriel, hardcoded.
#
# AND FOUR MORE INTRODUCED WHILE FIXING, which only showed up by RUNNING
#  · confirm() used ${ans,,}, a bash 4ism: macOS ships bash 3.2, where the
#    expansion error aborts the function, returning "yes" by accident. It
#    showed up while testing the questionnaire under a pty with expect;
#    bash -n doesn't catch it.
#  · config.env was written without quotes, and VM_FULLNAME="Omarchy ARM"
#    made "ARM" execute as a command on source: chroot died with rc=127.
#  · ph_verify's heredoc wasn't quoted, so the host's bash expanded the
#    $(...) and the checks ran ON THE MAC (pgrep with BSD syntax, systemctl
#    missing) instead of inside the VM. Rewritten with <<'"'"'EXPEOF'"'"'
#    and variables passed via Tcl's $env(...).
#  · spice-vdagentd is a "static" unit: it can't be enabled directly. You
#    have to enable spice-vdagentd.socket. Revealed by the freshly built VM.
#
# VALIDATION
#  Full build from scratch (8/8 phases) on 2026-08-23 on an M3 Max:
#   · 17/17 tools compiled (only herdr fails, due to the Zig version)
#   · extras=yes menu=yes hook=yes  <- the three blockers, resolved
#   · verify inside the guest: H=1 Q=1 BINS=436 -> VERDICT_OK
#   · final image 4.1 GB; ~57 min without OBS/Pinta, ~1h50 with them
#  And the call stage3 makes for OBS and Pinta, tested separately on that
#  same VM: rc=0, obs-studio 32.2.2-1, pinta 3.1.2-2, /usr/bin/obs ELF ARM
#  aarch64.
echo "Documentation record. The fixes live in build-omarchy-arm.sh and provision/src/."
