# btrfs compression

btrfs can compress file data transparently: it compresses as it writes and
decompresses as it reads, so programs see ordinary files. `compress=zstd:1`
uses zstd at its fastest level.

- **Space:** text, code, logs, configs and binaries typically shrink a lot;
  10-40% savings overall is common. Photos, video and archives are already
  compressed, so btrfs detects that and stores them as-is.
- **SSD writes:** fewer bytes reach the disk.
- **Speed:** zstd level 1 compresses at hundreds of MB/s to GB/s per core,
  which is not noticeable on NVMe; reads can be slightly faster because less
  data is fetched. The cost is a little CPU on writes.
- **Not compressed:** NOCOW files, such as the hibernation swap file
  (`docs/hibernation.md`).

Only data written after it is turned on is compressed. Existing files stay as
they are until they are rewritten.

## Why `/etc/fstab` doesn't turn it on

Fedora's installer writes `compress=zstd:1` into `/etc/fstab` for `/` and
`/home`, but on an atomic install neither entry applies it:

- `/` is mounted in the initramfs by ostree-prepare-root from the kernel
  arguments (`root=`, `rootflags=`), not from fstab. The live `/` is a
  read-only composefs overlay, and an fstab entry for it only makes
  `systemd-remount-fs.service` fail with "overlay: No changes allowed in
  reconfigure". Drop the `/` line from fstab.
- Most btrfs mount options apply to the whole filesystem and are set by its
  first mount. The initramfs mounts the root subvolume first, without
  `compress`, so the `/home` entry's `compress=zstd:1` is ignored too.

So the option has to go on the first mount, through `rootflags=`.

## Check

```bash
findmnt -no OPTIONS /var    # compress=zstd:1 present means it is on
cat /proc/cmdline           # look for rootflags=
```

## Enable

```bash
sudo rpm-ostree kargs --delete=rootflags=subvol=root \
    --append=rootflags=subvol=root,compress=zstd:1
systemctl reboot
findmnt -no OPTIONS /var    # should now include compress=zstd:1
```

Keep `subvol=root` (or whatever `rootflags=` already holds) in the new value.
Don't use `--replace` here: it parses `KEY=VALUE=NEWVALUE`, so a value that
itself contains `=` is split wrongly ("No karg 'rootflags=subvol' found").
Deleting the old argument and appending the new one in one command does the
same thing as a single deployment.

## Disable

```bash
sudo rpm-ostree kargs --delete=rootflags=subvol=root,compress=zstd:1 \
    --append=rootflags=subvol=root
systemctl reboot
```

Data already written compressed stays readable; btrfs decompresses it on read
regardless of the mount option.
