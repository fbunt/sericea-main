# Wi-Fi power save on ThinkPads with the QCNFA765 (ath11k)

> **Status (2026-10-27): keep power save off unless a test says otherwise.**
> No upstream fix for the slowdown has been found. The override is a local
> file on the host, not something the image ships.

## Symptom

On AMD ThinkPads with the Qualcomm QCNFA765 card (WCN6855 chip, `ath11k_pci`
driver), Wi-Fi with 802.11 power save enabled suffers packet loss, slow
throughput and higher latency. It is often worst after a suspend/resume cycle.

## Current workaround on the X13 Gen 3 (21CM)

`/etc/NetworkManager/conf.d/wifi-powersave-off.conf` (added Sep 2024, owned
by no package):

```ini
[connection]
wifi.powersave = 2
```

`2` means "disable". It costs some idle battery, and tuned's `powersave`
profile doesn't override it.

## History

- **2021, commit `b2beffa7d9a6`** (kernel 5.17): ath11k turns on station-mode
  power save by default for QCA6390 and WCN6855 ([commit][ps-enable]).
- **Kernels 6.4.12–6.6.14 (2023–early 2024):** On the T14s Gen 3 AMD, power
  save has to be turned off "to prevent crippling packet losses and slow
  speeds" ([Fedora thread][fedora]).
- **Mar 2024, commit `01296b39`** (kernel 6.10, backported to 6.6.33 and
  6.8.12): the driver had been
  forcing power save on for interfaces that weren't running, so the "off"
  setting didn't survive suspend/resume and ping rose from about 5 ms to
  14–20 ms. The fix makes "off" stick; it doesn't make power save itself work
  well ([commit][commit], [thread][commit-thread]).
- **Still open on the Arch wiki:** the X13 Gen 4 AMD (same card) page still
  lists Wi-Fi as "significantly slower" after standby, with
  `iw dev wlp1s0 set power_save off` as the workaround ([wiki][arch-x13g4]).
- **Per-model list in the driver:** `ath11k_pm_quirk_table` in
  [`core.c`][core] picks how each listed model suspends, to fix spurious
  wake-ups ([kernel bug 219196][bz219196]). It does not cover throughput,
  and the X13 Gen 3 (`21CM`/`21CN`) isn't in it. A March 2026 patch to add the
  closely related T14s Gen 3 AMD was posted ([thread][t14sg3-quirk]); as of
  2026-10-27 it isn't in mainline.

As of kernel 7.2.11 with firmware `WLAN.HSP.1.1-03125-...-3.6510.41` (built
2024-04-17), nothing found shows the slowdown is fixed.

## Re-testing

Turn power save on until the next reboot or reconnect:

```bash
sudo iw dev wlp1s0 set power_save on
iw dev wlp1s0 get power_save
```

Compare `ping -c 50 <gateway>` and a speed test with power save on and off,
both right away and after a suspend/resume cycle. If power save holds up,
remove the override:

```bash
sudo rm /etc/NetworkManager/conf.d/wifi-powersave-off.conf
sudo systemctl restart NetworkManager
```

If it degrades, run `sudo iw dev wlp1s0 set power_save off` and keep the file.

The override is reapplied whenever NetworkManager reconnects, including after
resume, so set power save on again before testing the resumed state.

### Results, 2026-10-27

X13 Gen 3 AMD, kernel 7.2.12, firmware `.41`, BIOS 1.52, 5 GHz at about
-53 dBm. Ping went to the gateway, and the speed test used
`speed.cloudflare.com`.

| Power save | Ping avg (1 s interval) | Download | Upload | Idle draw on battery |
|---|---|---|---|---|
| off | ~11 ms | 140–190 Mbit/s | 23 Mbit/s | 3.4 W |
| on | ~20 ms | 130–194 Mbit/s | 23 Mbit/s | 4.5 W |
| on, after resume | ~17–21 ms | 156–266 Mbit/s | 24 Mbit/s | 4.2 W |

There was no packet loss or throughput collapse, before or after resume, so
the old failure no longer reproduces. Power save roughly doubles latency, and
it gave no measurable battery saving: idle draw varies by about 1 W between
samples, which is more than Wi-Fi power save saves on an idle link. The
override stays.

[ps-enable]: https://github.com/torvalds/linux/commit/b2beffa7d9a67b59b085616a27f1d10b1e80784f
[fedora]: https://discussion.fedoraproject.org/t/thinkpad-t14s-amd-gen3-6-7-x-kernels-suspend-crashes-qcnfa765-ath11k-wifi-issue/104887
[commit]: https://github.com/torvalds/linux/commit/01296b39d3515f20a1db64d3c421c592b1e264a0
[commit-thread]: https://yhbt.net/lore/ath11k/20240309113115.11498-1-quic_bqiang@quicinc.com/
[arch-x13g4]: https://wiki.archlinux.org/title/Lenovo_ThinkPad_X13_Gen_4_(AMD)
[core]: https://github.com/torvalds/linux/blob/master/drivers/net/wireless/ath/ath11k/core.c
[bz219196]: https://bugzilla.kernel.org/show_bug.cgi?id=219196
[t14sg3-quirk]: https://lists.infradead.org/pipermail/ath11k/2026-March/008254.html
