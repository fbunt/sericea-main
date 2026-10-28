# Suspend-then-hibernate

With the lid closed, a laptop on this image suspends and, after 30 minutes,
hibernates to a swap file on disk. That needs a per-machine swap file, which
`sudo enable-hibernation` creates; until then the lid just suspends.

## Why

The ThinkPad X13 Gen 3 (AMD) only has s2idle, which drains about 0.5-1% of
the battery per hour (~0.2-0.45 W) with the lid closed, so a laptop left
closed for 2-3 days came back dead. Hibernation draws nothing, and the
30-minute delay keeps short lid closes on instant suspend/resume.

## What the image ships

All of it is inert on a machine that never runs `enable-hibernation`:

- `/usr/lib/systemd/logind.conf.d/60-lid-suspend-then-hibernate.conf`: lid
  closed, on battery or AC, triggers suspend-then-hibernate; docked or with an
  external display it is ignored (logind's default). When hibernation is not
  possible, logind falls back to plain suspend for lid events and logs
  "Requested suspend-then-hibernate operation is not supported, using regular
  suspend instead." That fallback covers the lid only: an explicit
  `systemctl suspend-then-hibernate` is refused instead. Desktops have no lid.
- `/usr/lib/systemd/sleep.conf.d/60-hibernate-delay.conf`:
  `HibernateDelaySec=30min`. Hibernation after the delay happens on AC too.
- `var-swap-swapfile.swap`, enabled through `swap.target.wants` and skipped
  at boot unless `/var/swap/swapfile` exists. Priority 10, below zram (100),
  so zram still takes normal swapping and the disk file is overflow plus the
  hibernation target.
- An SELinux file-context rule labelling `/var/swap(/.*)?` as `swapfile_t`.
  logind and systemd-sleep are denied a swap file with the default `var_t`
  label and then report hibernation as unavailable.
- A tmpfiles.d entry creating `/var/lib/systemd/sleep`, where systemd-sleep
  keeps its battery discharge-rate estimate. SELinux does not let
  systemd-sleep create that directory itself; without it systemd-sleep logs
  "Failed to update ... Permission denied" and assumes a fixed 1h estimate.
- `/usr/bin/enable-hibernation`, the setup command below.

There are no `resume=` kernel arguments. systemd-sleep stores the swap
location in the `HibernateLocation` EFI variable, and the initramfs's
systemd-hibernate-resume-generator resumes from it. This needs an EFI boot.

## Enable it

```bash
sudo enable-hibernation            # 16 GiB swap file
sudo enable-hibernation --size 32G # or pick the size; RAM size is the safe pick
```

It checks that hibernation can work (btrfs `/var` with the `single` data
profile, `disk` in `/sys/power/state`, kernel lockdown off, EFI boot, enough
free space), creates the `/var/swap` btrfs subvolume (kept out of snapshots of
its parent) and a NOCOW swap file in it, labels it, starts the swap unit, and
prints a status summary. `CanHibernate` and `CanSuspendThenHibernate` should
read `"yes"`. It is safe to re-run.

Kernel lockdown, which Secure Boot turns on with Fedora's kernel, disables
hibernation; the command refuses in that case.

It also refuses when the NVIDIA kernel driver is loaded or installed, as in
the `sericea-main-nvidia` image, because hibernating and resuming with that
driver has not been tested there. The driver's own power-management setup is
in place: the `xorg-x11-drv-nvidia-580xx-power` package, a dependency of the
driver, sets `NVreg_PreserveVideoMemoryAllocations=1` and ships the
`nvidia-suspend`, `nvidia-hibernate` and `nvidia-resume` units, which its
preset enables. `--allow-nvidia` skips the check for someone willing to try it.

## Test it

1. Hibernate directly: `systemctl hibernate`. The machine powers off; power it
   on and it should come back with windows intact. `journalctl --list-boots`
   should show no new boot: a resume continues the same one.
2. Suspend-then-hibernate with a short delay. Put a temporary drop-in in
   `/etc` and fix its label. A drop-in under `/run/systemd/sleep.conf.d` is
   silently ignored: SELinux denies systemd-sleep reading that directory.

   ```bash
   sudo mkdir -p /etc/systemd/sleep.conf.d
   printf '[Sleep]\nHibernateDelaySec=2min\n' |
     sudo tee /etc/systemd/sleep.conf.d/99-hibernate-delay-test.conf
   sudo restorecon -R /etc/systemd/sleep.conf.d
   ```

   Close the lid. After 2 minutes the RTC wakes the machine; the screen may
   come on briefly while the hibernation image is written, then it powers
   off. Power it on: it should resume into the same boot as above.
   `journalctl -b -u systemd-suspend-then-hibernate.service` shows the
   sequence. Remove the test drop-in afterwards:

   ```bash
   sudo rm /etc/systemd/sleep.conf.d/99-hibernate-delay-test.conf
   ```

`ls -Zd /var/lib/systemd/sleep` should show `systemd_sleep_var_lib_t`.

The sleep drop-ins are read on each request. A changed logind drop-in takes
effect after `sudo systemctl reload systemd-logind` (or a reboot); don't
restart logind from inside the graphical session.

## Turn it off

Remove the swap file; the lid goes back to plain suspend:

```bash
sudo systemctl stop var-swap-swapfile.swap
sudo rm /var/swap/swapfile
sudo btrfs subvolume delete /var/swap
```

To keep the swap file but stop the lid from hibernating, override the logind
drop-in under the same name:

```bash
sudo mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nHandleLidSwitch=suspend\nHandleLidSwitchExternalPower=suspend\n' |
  sudo tee /etc/systemd/logind.conf.d/60-lid-suspend-then-hibernate.conf
sudo restorecon -R /etc/systemd/logind.conf.d
sudo systemctl reload systemd-logind
```

Don't add the SELinux label with `semanage` on the host: a runtime `semanage`
rewrites `/etc/selinux/targeted`, which then stops following image updates.
