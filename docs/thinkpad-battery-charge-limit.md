# Battery charge limit on ThinkPads

upower has a built-in charge limit: when it's on, the battery stops charging
at 80% and starts again only below 75%. Keeping the battery below full slows
wear, at the cost of about 20% of each charge. While plugged in at the limit,
the laptop runs off the adapter and the battery sits idle ("Not charging"), so
the gap between the two numbers doesn't cause constant cycling.

The image ships nothing for this. upower's hwdb
(`/usr/lib/udev/hwdb.d/60-upower-battery.hwdb`) sets the default
`CHARGE_LIMIT=75,80`, and thinkpad_acpi exposes it as
`/sys/class/power_supply/BAT0/charge_control_{start,end}_threshold`.

## Why upower and not the firmware alone

The ThinkPad EC stores thresholds itself, but it can lose them. On the X13
Gen 3 (21CM) a 90/95 limit set years earlier reset to 0/100 when the battery
drained flat during suspend (2026-06-27), and nothing re-applied it. upower
saves its on/off state in `/var/lib/upower/charging-threshold-status` and
re-applies the thresholds every time upowerd starts or the battery appears,
so a reset lasts only until the next boot.

## Turn it on or off

No sudo is needed from the active session. Run it from a host terminal, not
through `distrobox-host-exec`:

```bash
busctl call org.freedesktop.UPower /org/freedesktop/UPower/devices/battery_BAT0 \
  org.freedesktop.UPower.Device EnableChargeThreshold b true   # or: b false
cat /sys/class/power_supply/BAT0/charge_control_{start,end}_threshold
upower -i /org/freedesktop/UPower/devices/battery_BAT0 | grep charge-threshold
```

`b false` charges to 100% and stays that way across reboots until you run
`b true` again. To charge to 100% once, until the next boot:

```bash
echo 100 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold
```

## Change the thresholds

Override upower's hwdb value with a local file that sorts after its
`60-upower-battery.hwdb`. When several hwdb records set the same key, the one
in the later-sorting file wins (hwdb(7)). Example for 70/80:

```bash
sudo tee /etc/udev/hwdb.d/61-battery-charge-limit.hwdb <<'EOF'
# Charge limit for upower's EnableChargeThreshold: start at 70%, stop at 80%.
# Sorts after upower's 60-upower-battery.hwdb, so this value wins.
battery:*:*:dmi:*
 CHARGE_LIMIT=70,80
EOF
sudo systemd-hwdb update
sudo udevadm trigger --action=change --subsystem-match=power_supply
udevadm info /sys/class/power_supply/BAT0 | grep CHARGE_LIMIT   # expect 70,80
sudo systemctl restart upower
```

Then run the `EnableChargeThreshold b true` command above. upower reads the
value when it starts, hence the restart. On this host the compiled hwdb lives
in `/etc/udev/hwdb.bin` and is rebuilt after image updates, so the `/etc`
file survives upgrades. To go back to the defaults, delete the file and repeat
the same steps.

thinkpad_acpi rejects a start threshold above the current stop and a stop
below the current start. upower writes start first, so lowering both works
through upower; when writing sysfs by hand, write start first.

Don't add TLP or a udev rule that writes the thresholds: TLP conflicts with
tuned, and a rule would fight upower's saved state.
