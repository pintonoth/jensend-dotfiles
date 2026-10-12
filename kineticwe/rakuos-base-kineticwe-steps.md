# RakuOS: base image + KineticWE instead of a preinstalled desktop

**Who this is for:** anyone who would rather run RakuOS's immutable base with a
lightweight tiling desktop (KWin + Noctalia, the "KineticWE" session) than one of the
shipped KDE / GNOME / COSMIC editions.

**Why it takes a rebase:** RakuOS publishes only desktop editions as ISOs. There is no
"base" or "minimal" ISO to install instead — verified 2026-10-12 on
`rakuos.org/download` and the SourceForge release listing: only `rakuos-{kde,gnome,cosmic}`
and their `-nvidia` variants exist as install media, while
`quay.io/rakuos/rakuos-base`, `quay.io/rakuos/rakuos-base-nvidia` and (staging-only)
`quay.io/rakuos/rakuos-minimal` exist only as container images (bootc targets).

So the path is: **install a desktop edition → rebase to the base image → install
KineticWE.** The edition you start from is only install media: KDE, GNOME and COSMIC all
work the same way, and the `-nvidia` variant is the one to use on NVIDIA hardware.

**Status of these instructions:** the whole path was executed and verified end to end on
a KVM guest on 2026-10-12 — rebase, overlay install, greeter, session — including the
boot-time measurements quoted in section 7. Everything this setup changes on the machine
is listed in *"Every local change this makes"*, with how to undo each one, because a few
of them are what make it usable rather than merely installed.

**Automated version:** `rakuos-kineticwe.sh` performs all of the steps below in two
stages, and carries itself across the reboot with a systemd timer so you do not have to
follow a checklist:

    sudo ./rakuos-kineticwe.sh --stage1     # in the installed desktop session
    sudo ./rakuos-kineticwe.sh --status     # read-only: image, markers, timers, sessions
    sudo ./rakuos-kineticwe.sh --stage2     # normally automatic after the reboot

It adds `--nvidia` (auto-detected otherwise), `--vm-serial`, `--dry-run`, `--yes`,
`--user NAME` and `--no-reboot`. The manual steps below remain the source of truth for
what the script does — read them when something goes wrong.

---

## 0. Install media and base install

- ISO: `rakuos-kde-latest-amd64.iso` (AMD/Intel) or `rakuos-kde-nvidia-latest-amd64.iso`
  (NVIDIA). Any edition works — GNOME and COSMIC are equally fine as the starting point.
- Write with `dd` / Fedora Media Writer / Etcher, boot it, run the Anaconda installer
  (UEFI, 40 GB+). Secure Boot may stay enabled or disabled — the current download page
  says both work, and the installer enrolls its own keys.
- Reboot into the installed desktop and get online: everything below needs network.

Optional, if you want to do the rest from another machine:

    sudo systemctl enable --now sshd        # install openssh-server first if missing

## 1. In the installed session: fix the login shells (do not skip this)

    chsh -s /bin/bash
    sudo chsh -s /bin/bash root

Why: `/etc` is carried into the new deployment, and the base image ships no `fish` —
which the desktop editions set as the login shell. Skip this and the first login after
the rebase accepts your password, flashes, and drops you back at the greeter.

## 2. Rebase to the base image

    sudo bootc switch quay.io/rakuos/rakuos-base:latest            # AMD / Intel
    sudo bootc switch quay.io/rakuos/rakuos-base-nvidia:latest     # NVIDIA
    sudo systemctl reboot

Why `quay.io` and not `ghcr.io`: the `ghcr.io/rakuos` mirror is months stale (Fedora 43
while the current line is 44) and its `latest` still resolves, so switching to it
silently moves the system back a release — which breaks the result.

After the reboot you are on a text console with no desktop. That is expected: the base
image is console-only by design. On real hardware Ctrl+Alt+F1…F6 work normally.

## 3. At the console: confirm the image and enable the KineticWE repo

    bootc status | head -5
    sudo dnf copr enable linuxgamerlife/lgl-experimental

If the `copr` helper is unavailable, install the repo file by hand (URL verified):

    sudo curl -fsSL -o /etc/yum.repos.d/lgl-experimental.repo \
      https://copr.fedorainfracloud.org/coprs/linuxgamerlife/lgl-experimental/repo/fedora-44/linuxgamerlife-lgl-experimental-fedora-44.repo

That repo (Fedora 44 chroot) provides `kineticwe`, `kineticwe-greeter`,
`kineticwe-noctalia` and `xdg-desktop-portal-kwe`.

## 4. Install KineticWE — including a terminal, which is *not* automatic

    sudo rum install kineticwe kineticwe-greeter kineticwe-noctalia \
                     xdg-desktop-portal-kwe alacritty

(`sudo rakuos install <pkg>` is the FAQ's equivalent form; `rum` and `dnf` both write to
the same persistent `/usr` overlay.)

Why `alacritty` is named explicitly: KineticWE only *recommends* it
(`rpm:recommends`), and weak dependencies are off in this install path — so a fresh
KineticWE session otherwise has **no terminal of any kind**, which is exactly what bit us
on the first attempt. Same reasoning applies to any other "nice to have" you expect.

## 5. Make `packages.list` the complete truth, then verify the install finalized

    printf '%s\n' firefox kineticwe kineticwe-greeter kineticwe-noctalia \
                       xdg-desktop-portal-kwe alacritty \
      | sudo tee /var/lib/rakuos/packages.list

    ls -la /var/lib/rakuos/rum-rpmdb        # must exist before you reboot

Two markers, two jobs:

- `/var/lib/rakuos/packages.list` is what RakuOS re-installs from whenever it has to
  rebuild the overlay (see *Future RakuOS updates*). If a package is not in that list, it
  does not come back. Keep it complete.
- `rum-rpmdb` existing is the marker that switches off the initramfs "pre-rum install"
  detection. If the install did not finalize (network hiccup, or you interrupted it) the
  next boot wipes the whole overlay — the install → reboot → everything-gone loop.

## 6. Reboot into the greeter

    sudo systemctl reboot

You should get the Noctalia greeter offering a **KineticWE** session. If no greeter
appears:

    sudo kineticwe-setup-greeter
    sudo systemctl enable --now greetd      # makes greetd the display manager

## 7. Check whether the overlay sync completed — this check decides the rest

Run it; it tells you whether the deferral below is needed at all.

    ls -l /var/lib/rakuos/overlay.state     # the "overlay install finished" marker

- **Marker present** → the vendor path worked end to end. Change nothing: the sync has
  nothing left to do, and the greeter's wait for it is ~0 s.
- **Marker missing** (even though you had network) → the sync never finished, so *every*
  boot the login screen waits for its probe, and packages queued in `packages.list` never
  install. Apply the deferral below.

**Why it can wedge.** The base image pulls `rakuos-overlay-sync` into the boot path via
`usr/lib/systemd/system/display-manager.service.d/rakuos-overlay-sync.conf`
(`Wants=rakuos-overlay-sync.service`), and systemd does not mark a target "reached" until
every wanted oneshot in its transaction has finished. The sync's only network check is

    curl -fsSLI --max-time 5 --connect-timeout 3 https://mirrors.fedoraproject.org/

— a **3-second** timeout. On a slow first name-resolve it fails, the sync defers with
exit 0, and the state marker above is never written, so it retries forever.

**Two different delays get confused here — keep them apart:**

- the **vendor wiring** costs ~0–10 s per boot once the install has completed, and on a
  *fresh* switch the sync is doing work you want (installing `packages.list`), so
  suppressing it there would be wrong;
- a **retry gate** in front of it costs its whole timeout on every boot and buys nothing.
  We tried one (60 × 3 s curl against that same URL, which could not succeed that early):
  it added **180 s** to every boot — the 3 min 34 s boot. Never do that; defer the work
  instead.

### The deferral (only if the marker is missing)

`/etc/systemd/system/rakuos-overlay-sync.service.d/20-defer-to-timer.conf`

    [Unit]
    Before=
    [Service]
    ExecStart=
    ExecStart=/bin/true

`/etc/systemd/system/rakuos-overlay-sync-deferred.service` (no `[Install]` section)

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

`/etc/systemd/system/rakuos-overlay-sync.timer`

    [Unit]
    Description=RakuOS Overlay Sync trigger (two minutes after boot)
    [Timer]
    OnBootSec=2min
    Unit=rakuos-overlay-sync-deferred.service
    [Install]
    WantedBy=timers.target

Then arm it:

    sudo mkdir -p /etc/systemd/system/timers.target.wants
    sudo ln -sf /etc/systemd/system/rakuos-overlay-sync.timer \
                /etc/systemd/system/timers.target.wants/rakuos-overlay-sync.timer
    sudo systemctl daemon-reload

**Measured on the machine this was built on** (2026-10-12, second run after the fixes):
userspace boot went from 3 min 31 s to **3.4 s**, the whole boot to **6.0 s** on 16 vCPUs,
and the login prompt arrived with no unit holding it. The deferred timer fired **~2 min
45 s** after boot rather than exactly 2 min — harmless, but do not rely on the exact number.

That same boot settled the probe question: the deferred sync logged
`no internet — deferring install` **2 min 45 s into a boot whose network was working**
(NTP was synced, `dnf` installs succeeded in the session). So on this machine the vendor
probe never succeeds and a queued `packages.list` install will never happen *through it*.
If yours behaves the same, do the install with a client that has real timeouts:

    sudo rum install $(grep -vE '^[[:space:]]*(#|$)' /var/lib/rakuos/packages.list)

Older note, still true and still the useful framing: the vendor wiring alone costs ~0–10 s
per boot once the install has completed, and the gate is what turns that into minutes.

---

## Future RakuOS updates: what survives, what does not

### A normal update (`bootc upgrade`, or RakuOS's updater app)

Survives:

- **Overlay packages** — KineticWE, alacritty, Firefox: that is the point of the `/usr`
  overlay, and `upper` lives on `/var`.
- **`/var`** — `packages.list`, overlay state, Flatpaks, your home directory.
- **The `/etc` changes below** — the deferral drop-in, the timer, the deferred unit, the
  COPR file. They live in `/etc`, which is carried forward and merged into the new
  deployment, while the *unit they override* lives in the image and gets replaced. That
  is precisely why the fix is a drop-in and not an edit of the vendor unit.
- **Rollback** — the previous deployment stays bootable: `sudo bootc rollback`, or pick
  the older entry in the boot menu.

Does **not** survive: **the serial console karg.** `bootc upgrade` writes a fresh BLS
entry for the new deployment using the kargs it finds in `usr/lib/bootc/kargs.d/`; an
edit to `/boot/loader/entries/*.conf` applies only to the entries that exist today.

Durable fix — put the karg where bootc looks for them. `/usr` is overlay-backed, so it is
writable:

    sudo mkdir -p /usr/lib/bootc/kargs.d
    printf 'kargs = ["console=ttyS0,115200", "console=tty0"]\n' | \
      sudo tee /usr/lib/bootc/kargs.d/50-local-serial.toml

The image ships exactly one such file (`10-rakuos.toml`, same `kargs = [...]` shape), and
bootc scans the *running* `/usr` — image plus overlay. Not verified from here: RakuOS also
ships a `rakuos-base-protect` tool, and if it prunes unexpected files under `/usr` this
would be undone. Confirm once after the next upgrade with `cat /proc/cmdline`; if the karg
is gone, re-add it to the new BLS entry:

    sudo sed -i '/^options /s/$/ console=ttyS0,115200 console=tty0/' \
        /boot/loader/entries/*.conf

### A Fedora release bump (44 → 45)

This one is by design and worth knowing in advance. RakuOS auto-schedules a **soft
overlay reset** when `/var/lib/rakuos/os-version` no longer matches `/etc/os-release`. It
wipes the overlay but preserves `packages.list`, local RPMs and user markers, then
re-installs from that list on the next boot with network.

Two consequences:

1. **`packages.list` is your source of truth** — that is why step 5 makes it complete. If
   `kineticwe-noctalia` and `xdg-desktop-portal-kwe` are not in it, they are simply gone
   after the bump.
2. **The 3-second probe becomes a real risk.** If the sync cannot reach its mirror on that
   boot, the soft reset leaves you with a wiped overlay and nothing reinstalled — no
   KineticWE, just the base console. This is the strongest argument for either applying
   the deferral/wait fix or, after a bump, logging in and running the install by hand:

       sudo rum install $(grep -v '^\s*#' /var/lib/rakuos/packages.list | grep -v '^\s*$')

Also: on a bump to Fedora 45 the overlay packages are fc44 RPMs and the COPR currently
publishes only fc44 — expect to wait for fc45 builds before KineticWE comes back.

### After every update, five lines

    bootc status                                            # what booted / what is staged
    systemctl cat rakuos-overlay-sync.service | tail -15    # is the drop-in still merged?
    systemctl list-timers rakuos-overlay-sync.timer         # is the deferral still armed?
    cat /var/lib/rakuos/packages.list                       # is the reinstall list complete?
    rum list --installed | grep -i kinetic                  # is the overlay actually intact?

If the greeter or the session breaks after an update: `sudo bootc rollback`, reboot, and
investigate from the working deployment.

---

## Every local change this makes (and how to undo it)

Nothing here is hidden in the image: every change is a file you can read and delete. The
only thing we *removed* is listed first, because it was a mistake worth not repeating.

| What | Where | Why | To undo |
|---|---|---|---|
| **Internet gate** (tried, then deleted) | `/etc/rakuos-wait-internet.sh` + `.../rakuos-overlay-sync.service.d/10-wait-for-internet.conf` | Attempted fix for the sync's network race. It never succeeded and added its full 180 s timeout to every boot. **Do not re-add it** — defer the work instead. | Delete both files, `systemctl daemon-reload` |
| Login shells | `/etc/passwd` (`chsh`) | `/etc` carries into the new deployment; the base image has no `fish`, which the desktop editions set as the login shell | `chsh -s /usr/bin/fish` on an edition that ships it |
| COPR repo | `/etc/yum.repos.d/lgl-experimental.repo` | Where the KineticWE RPMs come from (experimental, third-party) | Delete the file |
| Package source of truth | `/var/lib/rakuos/packages.list` | What RakuOS re-installs after any overlay rebuild, e.g. a release bump. Keep the full set here, not just the packages you typed on the command line | Edit the file (it is the only source of truth) |
| Boot-time sync neutered | `/etc/systemd/system/rakuos-overlay-sync.service.d/20-defer-to-timer.conf` | Stops the boot waiting for the sync's 3-second network probe; `Before=` clears the vendor ordering, `ExecStart=/bin/true` makes the boot-time run a no-op | Delete the file, `systemctl daemon-reload` |
| Real sync, on its own unit | `/etc/systemd/system/rakuos-overlay-sync-deferred.service` | Lets the real sync run from a timer without holding the boot | Delete the file |
| Deferred trigger | `/etc/systemd/system/rakuos-overlay-sync.timer` + symlink in `/etc/systemd/system/timers.target.wants/` | Runs the sync 2 min after boot, when the network genuinely works | Delete both, `systemctl daemon-reload` |
| Serial console karg | `/usr/lib/bootc/kargs.d/50-local-serial.toml` (durable) or `/boot/loader/entries/*.conf` (per-entry) | Only needed for VM/serial-console access; harmless on real hardware where the VTs already work | Delete the file / re-run the sed without the karg |
| *(VM only)* serial device + helper | `<vm-dir>/launch.sh` (`-serial unix:...`), `~/vm-console.sh` | Gives a text console for a VM whose window cannot be reached with Ctrl+Alt+F# (the host desktop grabs that chord) | Remove the `-serial` line; delete the script |

Note on the vendor material: the unit being overridden
(`usr/lib/systemd/system/rakuos-overlay-sync.service`) and the drop-in that pulls it into
boot (`usr/lib/systemd/system/display-manager.service.d/rakuos-overlay-sync.conf`) belong
to the image and will be replaced by updates. Our behaviour keeps applying through `/etc`.
If RakuOS ever renames the unit or ships its own timer, our drop-in goes stale and the
sync may run twice — `systemctl cat rakuos-overlay-sync.service` shows whether the drop-in
is still merged.

---

## Caveats

- On NVIDIA hardware use the `-nvidia` ISO **and** `quay.io/rakuos/rakuos-base-nvidia`;
  and note that KineticWE itself on NVIDIA is untested by us (the KDE/GNOME nvidia
  editions are the supported ones) — keep a live USB and expect to roll back.
- `linuxgamerlife/lgl-experimental` is a third-party *experimental* COPR: expect churn,
  and re-check package names before relying on it.
- Downloads: the rebase pulls ~3.5 GB; KineticWE pulls KWin/KF6/Qt6 on top.
- KineticWE is KWin + Noctalia on Wayland and needs a working GPU driver (Mesa for
  AMD/Intel). You are on a console between steps 2 and 6 — be comfortable there, or set up
  sshd beforehand.
- The overlay survives minor updates, but it is still an overlay: a botched install, a
  release bump, or a scheduled `rakuos-reset-overlay` can rebuild it. `packages.list` is
  the file that decides what you get back.

## Possible shortcut (untested by us)

KineticWE's packages are plain Fedora 44 RPMs, so a **Fedora 44 Kinoite** install (which
already ships KWin/KF6) might reach the same desktop with just

    sudo dnf copr enable linuxgamerlife/lgl-experimental
    sudo dnf install kineticwe kineticwe-greeter alacritty

with no RakuOS rebase and no image switch. We have not tried it — treat it as an
experiment, not as instructions.

---

## Appendix: testing and verifying this in a VM

Optional, and only relevant if you reproduce this on a virtual machine (as we did) rather
than on hardware.

**Text console in a VM.** A QEMU window with `-display sdl,gl=on` gives you no reachable
text console, because Ctrl+Alt+F# is grabbed by the host desktop before QEMU sees it. Add
a serial console instead:

1. In `<vm-dir>/launch.sh`, add to every `qemu-system-x86_64` invocation, just before
   `-usb`:

       -serial unix:"$VM_DIR/serial.sock",server=on,wait=off

2. In the guest, add the karg (keep `console=tty0` last so `/dev/console` stays
   graphical):

       sudo sed -i '/^options /s/$/ console=ttyS0,115200 console=tty0/' \
           /boot/loader/entries/*.conf

3. Attach from the host:

       ~/vm-console.sh <vm-dir>        # raw passthrough, Ctrl-] quits
       nc -U <vm-dir>/serial.sock      # quick look

   Only one client at a time. A `login:` prompt means the guest reached multi-user, i.e.
   the boot finished — which is how the 15 s number above was measured.

**Switching VTs from the host.** The VM's QMP socket can press keys for you, which is how
we got to a text console without the key chord:

    {"execute":"human-monitor-command","arguments":{"command-line":"sendkey ctrl-alt-f2"}}

Inside the QEMU window, `Ctrl+Alt+2` opens QEMU's own monitor, where `sendkey ctrl-alt-f1`
switches back to the session, and `Ctrl+Alt+1` returns to the guest display.

**Measuring a boot objectively.** `journalctl --list-boots` then
`journalctl -D /path/to/journal --no-pager | grep -E 'Startup finished in .*=|Finished rakuos-overlay-sync|Started greetd|serial-getty@ttyS0'`
gives the userspace split and shows exactly which unit the greeter was waiting for.
