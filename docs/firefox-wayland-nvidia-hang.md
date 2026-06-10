# Firefox UI hangs on page load (NVIDIA + Wayland)

> **Now baked into the image.** `build-nvidia.sh` writes `MOZ_ENABLE_WAYLAND=0`
> to `/usr/lib/environment.d/90-nvidia-wayland.conf`, so Firefox on the NVIDIA
> variant runs on XWayland and does not hit this hang. This doc is kept as the
> rationale + diagnostics, and for working around it on systems that predate the
> fix or that already carry a conflicting `/etc` override.

## Symptom

Firefox's **entire UI freezes** while a page loads — commonly right after
clicking a search result. The window goes unresponsive (can't switch tabs,
can't click anything); it is not just the one tab. No crash, no error dialog.
Killing and relaunching Firefox does not help: it hangs again within a minute or
two, on fresh navigation. It survives a reboot and even a fresh Firefox profile.

Only the **NVIDIA variant** (`sericea-main-nvidia`) is affected; the base image
on AMD/Intel does native Wayland fine.

## Root cause

Firefox defaults to **native Wayland** when a Wayland display is present. On the
**proprietary NVIDIA driver**, the Wayland **EGL compositor path** wedges when
WebRender goes to paint certain page content. The browser's **main (UI) thread
blocks on a lock** waiting for the stalled compositor and stops pumping its event
loop — so the whole window freezes. Because it is a driver/compositor code-path
bug, not corrupt state, it is independent of your profile, history, shader cache,
and the OS image; resetting those changes nothing.

Launching with `MOZ_ENABLE_WAYLAND=0` routes Firefox through **XWayland**, which
uses a different rendering path and avoids the hang.

## How it was diagnosed

The signature of a hung instance (inspect from a distrobox sharing the host PID
namespace, or directly on the host):

```bash
# Whole process idle, but the main thread is parked on a futex (a lock),
# not on the Wayland event-loop poll it should be running:
ps -eo pid,stat,wchan,comm -p "$(pgrep -x firefox)"      # STAT 'Sl', wchan futex_do_wait
top -H -p "$(pgrep -x firefox)"                          # 0 running threads, ~0% CPU while frozen
cat /proc/"$(pgrep -x firefox)"/task/"$(pgrep -x firefox)"/syscall  # 202 = futex (FUTEX_WAIT)
```

What it is **not** (all ruled out before landing on the compositor path):

- **Not OOM / swap** — `free -h` showed >100 GiB free, 0 swap used.
- **Not a crash** — no minidumps in the profile, no coredumps.
- **Not a GPU hardware fault** — `journalctl -k` had no `NVRM`/`Xid` errors;
  `nvidia-smi -q` showed the GPU idle (~36 °C, P8, no thermal/power/HW slowdown).
- **Not the profile/storage** — a fresh profile (`firefox --ProfileManager`)
  still hangs, so it is not history/bookmarks/`places.sqlite`/extensions.
- **Not a corrupt shader cache** — after a driver update the new driver built a
  fresh `~/.cache/nvidia/GLCache` namespace and still hung.
- **Not the OS update** — it started before the update and persisted across it.

The discriminator: the exact same repro **does not hang** under
`MOZ_ENABLE_WAYLAND=0 firefox` (XWayland), which both confirms the cause and is
the fix.

## Quick test (non-persistent)

Quit Firefox, then launch it on XWayland and repeat the steps that hung it:

```bash
MOZ_ENABLE_WAYLAND=0 firefox
```

No hang → confirmed.

## Permanent fix

Baked into the NVIDIA image as a session-wide environment variable (only affects
Mozilla apps):

```ini
# /usr/lib/environment.d/90-nvidia-wayland.conf
MOZ_ENABLE_WAYLAND=0
```

`start-sway` evaluates `environment.d` for both the greeter and the user session,
so this applies to Firefox however it is launched (terminal or app launcher).
Take effect by logging out and back in.

On a machine that predates the fix, set it per-user instead:

```bash
mkdir -p ~/.config/environment.d
printf 'MOZ_ENABLE_WAYLAND=0\n' > ~/.config/environment.d/firefox-x11.conf
# log out / back in
```

## Notes / caveats

- **Trade-off:** XWayland gives up native-Wayland niceties (e.g. crisp fractional
  scaling, per-monitor DPI). On a single-display GTX 1070 this is usually
  unnoticeable. If you would rather keep native Wayland, try `about:config` →
  `gfx.webrender.compositor = false` instead, which disables just the native
  Wayland compositor path and often avoids the hang without dropping to XWayland.
- **Scope:** this is forced for the whole NVIDIA variant, which currently targets
  the proprietary 580 / Pascal (GTX 1070) driver. A future Turing+ card on a
  newer driver may not need it; revisit `MOZ_ENABLE_WAYLAND=0` if you swap the
  `NVIDIA_DRIVER` branch and confirm native Wayland is stable there.
- **Upstream:** this is a Firefox + proprietary-NVIDIA Wayland bug. If a specific
  page reproduces it reliably, a core of the hung process (`coredumpctl`, then
  read the main-thread stack offline) gives a precise repro/stack to attach to a
  report at <https://bugzilla.mozilla.org>.
```