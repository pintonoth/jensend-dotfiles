#!/usr/bin/env bash
# rakuos-kineticwe — turn a RakuOS desktop installation into base RakuOS + KineticWE.
#
#   stage 1   run in the installed desktop session: fixes login shells, rebases to the
#             base image, arms stage 2 to run automatically after the reboot
#   stage 2   runs by itself after the reboot (via a timer, so the boot is never held):
#             enables the COPR, installs KineticWE, checks the overlay markers, applies
#             the boot-sync deferral if the image needs it, arms the greeter
#   status    read-only: prints everything this script cares about
#
# Usage:
#   sudo ./rakuos-kineticwe.sh --stage1 [--nvidia] [--vm-serial] [--yes]
#   sudo ./rakuos-kineticwe.sh --stage2                              # normally automatic
#   sudo ./rakuos-kineticwe.sh --status
#
# Options:
#   --nvidia      force the -nvidia base image (otherwise auto-detected)
#   --vm-serial   also enable a serial console (VM testing; requires `-serial` in the
#                 VM's QEMU command line, see the companion .md)
#   --dry-run     print what would happen, change nothing
#   --yes         do not ask for confirmation (implied by --auto)
#   --auto        non-interactive, as used by the stage-2 timer unit
#   --user NAME   desktop user whose login shell to fix (default: $SUDO_USER)
#   --no-reboot   never offer to reboot at the end
#   --help
#
# Revert: see "Every local change this makes" in rakuos-base-kineticwe-steps.md, or run
#   --status to see exactly which of the local files exist on this machine.

set -Eeuo pipefail

# ---------------------------------------------------------------- constants

STAGE=""
IMG_AMD64="quay.io/rakuos/rakuos-base:latest"
IMG_NVIDIA="quay.io/rakuos/rakuos-base-nvidia:latest"
COPR="linuxgamerlife/lgl-experimental"
COPR_REPO_URL="https://copr.fedorainfracloud.org/coprs/${COPR}/repo/fedora-44/linuxgamerlife-lgl-experimental-fedora-44.repo"
PKGS=(kineticwe kineticwe-greeter kineticwe-noctalia xdg-desktop-portal-kwe alacritty firefox)
STATE_DIR="/var/lib/rakuos"
MARKER="$STATE_DIR/.kineticwe-stage2-pending"
SELF_DEST="/usr/local/bin/rakuos-kineticwe"
UNIT_S2="rakuos-kineticwe-stage2.service"
UNIT_S2_TIMER="rakuos-kineticwe-stage2.timer"
LOG="/var/log/rakuos-kineticwe.log"

DRY_RUN=0; ASSUME_YES=0; AUTO=0; FORCE_NVIDIA=0; VM_SERIAL=0; NO_REBOOT=0
TARGET_USER="${SUDO_USER:-}"

# ---------------------------------------------------------------- output

if [ -t 1 ]; then C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_0=$'\e[0m'
else C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""; fi

step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '\n%serror:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

run() {                       # run a command, or print it in --dry-run
    if [ "$DRY_RUN" = 1 ]; then printf '    [dry-run] %s\n' "$*"; return 0; fi
    printf '    $ %s\n' "$*"
    "$@"
}

confirm() {
    local q="$1"
    [ "$ASSUME_YES" = 1 ] && return 0
    [ "$DRY_RUN" = 1 ] && return 0
    printf '\n    %s [y/N] ' "$q"
    local a; read -r a </dev/tty || return 1
    case "$a" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- detection

need_root() { [ "$(id -u)" = 0 ] || die "run this with sudo (it rebases the OS and installs packages)."; }

is_rakuos() {
    [ -e /var/lib/rakuos ] && command -v bootc >/dev/null && return 0
    grep -qiE '^ID(_LIKE)?=.*(rakuos|fedora)' /etc/os-release 2>/dev/null \
        && [ -e /var/lib/rakuos ] && return 0
    return 1
}

have_desktop() {
    command -v plasmashell >/dev/null || command -v gnome-shell >/dev/null \
        || command -v cosmic-session >/dev/null
}

current_image() {
    bootc status 2>/dev/null | grep -oE 'quay\.io/rakuos/[a-z0-9.-]+(:[a-zA-Z0-9._-]+)?' | head -1
}

on_base_image() {
    case "$(current_image)" in *rakuos-base*) return 0 ;; *) return 1 ;; esac
}

detect_nvidia() {
    [ "$FORCE_NVIDIA" = 1 ] && return 0
    command -v lspci >/dev/null || return 1
    lspci 2>/dev/null | grep -qiE '(vga|3d|display).*nvidia'
}

is_vm() { command -v systemd-detect-virt >/dev/null && systemd-detect-virt -q; }

free_space_gb() { df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9'; }

wait_for_internet() {         # generous on purpose: a 3s probe is what went wrong upstream
    local tries="${1:-8}" i
    for i in $(seq 1 "$tries"); do
        if [ "$DRY_RUN" = 1 ]; then return 0; fi
        if curl -fsS -o /dev/null --connect-timeout 10 --max-time 25 https://mirrors.fedoraproject.org/; then
            ok "internet reachable (attempt $i)"; return 0
        fi
        info "waiting for internet… ($i/$tries)"
        sleep 10
    done
    return 1
}

# ---------------------------------------------------------------- stage 1

stage1() {
    step "Preflight"
    is_rakuos || die "this is not a RakuOS installation (no /var/lib/rakuos + bootc). For a plain Fedora/Kinoite system, see the 'Possible shortcut' section of the .md instead."
    [ -n "$TARGET_USER" ] || die "cannot tell which user to fix; pass --user NAME"
    id "$TARGET_USER" >/dev/null 2>&1 || die "no such user: $TARGET_USER"
    have_desktop || die "no desktop detected — you are probably already on the base image. Run: sudo $(basename "$0") --stage2"
    local img; if detect_nvidia; then img="$IMG_NVIDIA"; info "NVIDIA GPU detected"; else img="$IMG_AMD64"; fi
    local free; free="$(free_space_gb)"; [ -n "$free" ] && [ "$free" -lt 8 ] && \
        die "only ${free}G free on /; the rebase needs ~4 GB plus room to unpack. Free some space first."
    info "target image : $img"
    info "current image: $(current_image)"
    info "desktop user : $TARGET_USER"
    wait_for_internet || die "no internet — nothing here works offline. Get online and re-run."
    confirm "Rebase this machine to ${img} and install KineticWE in a second stage?" || die "aborted."

    step "Fix login shells (prevents the login loop after the rebase)"
    # /etc carries into the new deployment, and the base image ships no fish — which the
    # desktop editions set as the login shell.
    for u in "$TARGET_USER" root; do
        local sh; sh="$(getent passwd "$u" | cut -d: -f7)"
        if [ "$sh" != "/bin/bash" ]; then
            run chsh -s /bin/bash "$u"; ok "$u: $sh -> /bin/bash"
        else
            ok "$u: already /bin/bash"
        fi
    done

    step "Arm stage 2 (runs by itself after the reboot)"
    if [ "$DRY_RUN" = 0 ]; then
        install -m 0755 "$0" "$SELF_DEST"
        touch "$MARKER"
        cat > "/etc/systemd/system/$UNIT_S2" <<'EOF'
[Unit]
Description=RakuOS KineticWE setup (stage 2)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/var/lib/rakuos/.kineticwe-stage2-pending
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rakuos-kineticwe --stage2 --auto
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
EOF
        cat > "/etc/systemd/system/$UNIT_S2_TIMER" <<'EOF'
[Unit]
Description=RakuOS KineticWE setup trigger (after boot)
# A timer, not WantedBy=multi-user.target: a wanted oneshot would hold multi-user.target
# (and therefore the login screen) until the install finished.
[Timer]
OnBootSec=45s
Unit=rakuos-kineticwe-stage2.service
[Install]
WantedBy=timers.target
EOF
        ln -sf "/etc/systemd/system/$UNIT_S2_TIMER" "/etc/systemd/system/timers.target.wants/$UNIT_S2_TIMER"
        systemctl daemon-reload
    else
        run install -m 0755 "$0" "$SELF_DEST"
    fi
    ok "stage 2 will run 45s after your next boot (logs: journalctl -fu $UNIT_S2)"

    step "Rebase"
    run bootc switch "$img"
    if [ "$VM_SERIAL" = 1 ]; then
        step "Serial console (VM only)"
        run mkdir -p /usr/lib/bootc/kargs.d
        if [ "$DRY_RUN" = 0 ]; then
            printf 'kargs = ["console=ttyS0,115200", "console=tty0"]\n' \
                > /usr/lib/bootc/kargs.d/50-local-serial.toml
            sed -i '/^options /s/$/ console=ttyS0,115200 console=tty0/' /boot/loader/entries/*.conf
        fi
        ok "karg written for this entry and for future deployments (needs -serial in QEMU)"
    fi

    step "Done with stage 1 — reboot to continue"
    info "You will land on a text console (no desktop); that is expected."
    info "Stage 2 runs automatically 45 s later. Watch it with:"
    info "    journalctl -fu $UNIT_S2"
    if [ "$NO_REBOOT" = 0 ] && confirm "Reboot now?"; then
        run systemctl reboot
    else
        info "When ready:  sudo systemctl reboot"
    fi
}

# ---------------------------------------------------------------- stage 2

apply_sync_deferral() {
    step "The overlay sync never completed — deferring it out of the boot path"
    if [ "$DRY_RUN" = 0 ]; then
        mkdir -p /etc/systemd/system/rakuos-overlay-sync.service.d
        cat > /etc/systemd/system/rakuos-overlay-sync.service.d/20-defer-to-timer.conf <<'EOF'
# The image wires rakuos-overlay-sync into boot twice (Before= in the unit itself, and
# Wants= from usr/lib/systemd/system/display-manager.service.d/rakuos-overlay-sync.conf),
# and systemd does not reach a target until every wanted oneshot has finished — so the
# login screen waits for the sync, whose only network check is a 3-second curl that fails
# early on some networks. Boot-time run reduced to a no-op; the real sync is deferred to
# rakuos-overlay-sync.timer. Revert: delete this file, the two units and the timer symlink.
[Unit]
Before=
[Service]
ExecStart=
ExecStart=/bin/true
EOF
        cat > /etc/systemd/system/rakuos-overlay-sync-deferred.service <<'EOF'
[Unit]
Description=RakuOS Overlay Sync (deferred)
After=network-online.target systemd-resolved.service
Wants=network-online.target systemd-resolved.service
[Service]
Type=oneshot
ExecStart=/usr/libexec/rakuos/rakuos-overlay-sync
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
EOF
        cat > /etc/systemd/system/rakuos-overlay-sync.timer <<'EOF'
[Unit]
Description=RakuOS Overlay Sync trigger (two minutes after boot)
[Timer]
OnBootSec=2min
Unit=rakuos-overlay-sync-deferred.service
[Install]
WantedBy=timers.target
EOF
        ln -sf /etc/systemd/system/rakuos-overlay-sync.timer \
               /etc/systemd/system/timers.target.wants/rakuos-overlay-sync.timer
        systemctl daemon-reload
    else
        printf '    [dry-run] write sync drop-in + deferred unit + timer, daemon-reload\n'
    fi
    ok "boot no longer waits for the sync; it runs 2 min after boot instead"
}

stage2() {
    step "Stage 2: install KineticWE on the base image"
    is_rakuos || die "not a RakuOS installation."
    if have_desktop && ! on_base_image; then
        warn "this still looks like a desktop edition — did the stage 1 rebase not complete?"
        confirm "Continue anyway?" || die "aborted."
    fi
    info "image: $(current_image)"

    step "Internet"
    wait_for_internet || die "no internet — KineticWE cannot be installed. Re-run later: sudo $SELF_DEST --stage2"

    step "Enable the KineticWE COPR (${COPR})"
    if dnf repolist 2>/dev/null | grep -qi lgl-experimental; then
        ok "repo already enabled"
    else
        if ! run dnf copr enable -y "$COPR"; then
            warn "`dnf copr enable` failed; installing the repo file by hand"
            run curl -fsSL -o /etc/yum.repos.d/lgl-experimental.repo "$COPR_REPO_URL"
        fi
        ok "repo enabled"
    fi

    step "Install packages"
    info "set: ${PKGS[*]}"
    info "alacritty is named explicitly on purpose: kineticwe only *recommends* it and weak"
    info "deps are off here, so without it the session has no terminal at all."
    if [ "$DRY_RUN" = 1 ]; then
        printf '    [dry-run] rum install -y %s\n' "${PKGS[*]}"
    else
        local done_ok=0
        rum install -y "${PKGS[@]}"          && done_ok=1 \
        || rum install --assumeyes "${PKGS[@]}" && done_ok=1 \
        || dnf install -y "${PKGS[@]}"       && done_ok=1 \
        || warn "package install returned non-zero — check the output above"
        [ "$done_ok" = 1 ] || die "could not install the package set."
    fi

    step "Verify"
    local failed=0
    for f in /usr/bin/start-kineticwe /usr/bin/noctalia-greeter; do
        if [ "$DRY_RUN" = 1 ] || [ -e "$f" ]; then ok "$f present"; else warn "$f MISSING"; failed=1; fi
    done
    if [ "$DRY_RUN" = 1 ] || ls /usr/share/wayland-sessions/ >/dev/null 2>&1; then
        [ "$DRY_RUN" = 0 ] && info "sessions: $(ls /usr/share/wayland-sessions/ | tr '\n' ' ')"
    fi
    if [ "$DRY_RUN" = 0 ] && [ ! -e "$STATE_DIR/rum-rpmdb" ]; then
        warn "rum-rpmdb is missing — the overlay install may not have finalized."
        warn "Do NOT reboot yet: the initramfs treats that as a pre-rum install and wipes the overlay."
        die "re-run this stage once the install completes cleanly."
    fi
    [ "$failed" = 0 ] && ok "KineticWE payload in place"

    step "Add the package set to packages.list (merge — never discard what is already there)"
    if [ "$DRY_RUN" = 0 ]; then
        # This file is the machine's reinstall list and may already hold entries the user
        # put there (a file manager, a browser, a different KineticWE build name such as
        # kineticwe-git). Merge, so re-running this script can never drop someone's set.
        { cat "$STATE_DIR/packages.list" 2>/dev/null || true; printf '%s\n' "${PKGS[@]}"; } \
            | grep -vE '^[[:space:]]*(#|$)' | sort -u > "$STATE_DIR/packages.list.new"
        mv "$STATE_DIR/packages.list.new" "$STATE_DIR/packages.list"
        info "now: $(tr '\n' ' ' < "$STATE_DIR/packages.list")"
    else
        printf '    [dry-run] merge into %s: %s\n' "$STATE_DIR/packages.list" "${PKGS[*]}"
    fi
    info "RakuOS re-installs exactly this list whenever it rebuilds the overlay (e.g. a"
    info "Fedora release bump), so keep anything you care about in here."

    step "Overlay sync state"
    if [ -e "$STATE_DIR/overlay.state" ]; then
        ok "overlay.state present — the vendor path completed; leaving the units alone"
    else
        warn "overlay.state missing: the sync has never finished on this machine"
        apply_sync_deferral
    fi

    step "Arm the greeter"
    if [ "$DRY_RUN" = 0 ] && [ -x /usr/bin/kineticwe-setup-greeter ]; then
        run /usr/bin/kineticwe-setup-greeter || warn "kineticwe-setup-greeter returned non-zero"
    fi
    if command -v greetd >/dev/null || [ "$DRY_RUN" = 1 ]; then
        run systemctl enable greetd
        run systemctl start greetd
        ok "greetd enabled and started — the greeter should appear on tty1"
    else
        warn "greetd is not installed; run: sudo rum install greetd kineticwe-greeter"
    fi

    step "Stage 2 complete"
    if [ "$DRY_RUN" = 0 ]; then
        rm -f "$MARKER"
        systemctl disable --now "$UNIT_S2_TIMER" >/dev/null 2>&1 || true
    fi
    info "Look for the Noctalia greeter (tty1) and log into the KineticWE session."
    info "If it does not appear: press Ctrl+Alt+F2 (real hardware) and run"
    info "    systemctl status greetd --no-pager; journalctl -u greetd -n 30"
    info "After a future Fedora release bump, if KineticWE does not come back:"
    info "    sudo $SELF_DEST --stage2"
    if [ "$NO_REBOOT" = 0 ] && [ "$AUTO" = 0 ] && confirm "Reboot now to land on the greeter?"; then
        run systemctl reboot
    fi
}

# ---------------------------------------------------------------- status

status() {
    step "RakuOS / KineticWE status"
    if ! is_rakuos; then warn "this does not look like a RakuOS system"; return 1; fi
    info "image        : $(current_image)"
    info "virt         : $(is_vm && echo yes || echo no)"
    info "desktop      : $(have_desktop && echo yes || echo 'no (base image)')"
    local rv cv
    rv="$(cat /var/lib/rakuos/os-version 2>/dev/null || echo '?')"
    cv="$(. /etc/os-release; echo "${VERSION_ID:-?}")"
    if [ "$rv" = "$cv" ]; then ok "os-version matches /etc/os-release ($rv)"; else warn "os-version=$rv vs release=$cv — a mismatch triggers a soft overlay reset on next boot"; fi
    for m in rum-rpmdb overlay.state packages.list; do
        if [ -e "/var/lib/rakuos/$m" ]; then ok "/var/lib/rakuos/$m present"; else info "/var/lib/rakuos/$m absent"; fi
    done
    [ -e /var/lib/rakuos/packages.list ] && info "packages.list: $(tr '\n' ' ' < /var/lib/rakuos/packages.list)"
    for f in /usr/bin/start-kineticwe /usr/bin/noctalia-greeter; do
        [ -e "$f" ] && ok "$f" || warn "$f missing"
    done
    info "sessions     : $(ls /usr/share/wayland-sessions/ 2>/dev/null | tr '\n' ' ')"
    info "greetd       : $(systemctl is-enabled greetd 2>/dev/null || echo n/a)/$(systemctl is-active greetd 2>/dev/null || echo n/a)"
    for u in rakuos-overlay-sync.timer "$UNIT_S2_TIMER"; do
        if systemctl list-timers --all 2>/dev/null | grep -q "${u%%\.timer}"; then
            ok "timer $u present"
        fi
    done
    if [ -e /etc/systemd/system/rakuos-overlay-sync.service.d/20-defer-to-timer.conf ]; then
        ok "boot-sync deferral in place"
    else
        info "boot-sync deferral not applied"
    fi
    if command -v bootc >/dev/null; then
        info "rollback     : sudo bootc rollback (previous deployment stays bootable)"
    fi
}

# ---------------------------------------------------------------- main

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --stage1) STAGE=1 ;;
        --stage2) STAGE=2 ;;
        --status) STAGE=status ;;
        --nvidia) FORCE_NVIDIA=1 ;;
        --vm-serial) VM_SERIAL=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --yes) ASSUME_YES=1 ;;
        --auto) AUTO=1; ASSUME_YES=1 ;;
        --no-reboot) NO_REBOOT=1 ;;
        --user) shift; TARGET_USER="${1:-}" ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

[ -n "$STAGE" ] || { usage; exit 1; }
[ "$STAGE" = status ] || need_root
if [ -w /var/log ] && [ -z "${RK_NO_LOG:-}" ]; then
    exec > >(tee -a "$LOG") 2>&1
fi
printf '%s\n' "=== rakuos-kineticwe $STAGE  $(date -u '+%F %T UTC') ==="

case "$STAGE" in
    1) stage1 ;;
    2) stage2 ;;
    status) status ;;
esac
