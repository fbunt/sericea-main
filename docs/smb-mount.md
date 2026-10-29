# Mounting an SMB share from media-server

The image already ships the client side (`cifs-utils`, `samba-client`,
`gvfs-smb`). The mount is per machine, because it needs credentials, so it
lives in that machine's `/etc` and not in the image.

The setup below mounts the share over Tailscale when the path is first
accessed and unmounts it after 10 minutes unused. Nothing talks to the
server while the share is idle, and boot never waits on it.

## Setup

Run on the host. This example mounts the `phone` share as user `phone` at
`/var/mnt/phone` (`/mnt` is a symlink to `/var/mnt` on Fedora Atomic). To
see the shares a user can reach, run `smbclient -L //media-server -U <user>`.

Credentials file, readable only by root:

```bash
sudo install -d -m 700 /etc/samba/credentials
sudo install -m 600 /dev/null /etc/samba/credentials/media-server
sudoedit /etc/samba/credentials/media-server
```

```
username=phone
password=...
```

Mount point and fstab entry:

```bash
sudo mkdir -p /var/mnt/phone
echo '//media-server.tail5003e7.ts.net/phone /var/mnt/phone cifs credentials=/etc/samba/credentials/media-server,uid=1000,gid=1000,file_mode=0644,dir_mode=0755,vers=3.1.1,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=10min,x-systemd.mount-timeout=30s,x-gvfs-hide 0 0' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo systemctl start var-mnt-phone.automount
```

Check it:

```bash
ls /var/mnt/phone        # the first access mounts it
findmnt /var/mnt/phone   # an autofs line, plus a cifs line while mounted
```

## What the options do

- `media-server.tail5003e7.ts.net`: the full Tailscale name, so the mount
  works away from home and doesn't depend on MagicDNS search domains.
- `credentials=`: keeps the password out of the world-readable fstab.
- `uid=1000,gid=1000,file_mode,dir_mode`: files appear owned by the local
  user, so writing needs no sudo. The server still enforces its own
  permissions.
- `vers=3.1.1`: SMB3 only. The server has SMB1 disabled.
- `x-systemd.automount`: systemd places an autofs trap at the mount point,
  and any access (`ls`, `cd`, a file manager, mpv) mounts the share. There is
  no manual remount.
- `x-systemd.idle-timeout=10min`: unmounts after 10 minutes with no open
  files and no process using it as its working directory.
- `nofail`, `_netdev`, `x-systemd.mount-timeout=30s`: boot doesn't wait on
  the share, and an unreachable server fails within 30 s instead of hanging.

- `x-gvfs-hide`: keeps gvfs from listing and probing the share. Without it,
  gvfs re-triggers the automount in the same second as each idle unmount, so
  the share never stays unmounted.

CIFS mounts are `soft` by default, so losing the server mid-use gives I/O
errors rather than hung processes. Before any sleep the image force-unmounts
CIFS shares and pauses their automounts, then restores the automounts on
resume (`unmount-cifs-around-sleep.service`, see `docs/hibernation.md`). A
share left mounted would otherwise block hibernation.

Add `ro,` at the start of the options for a read-only mount.

## Troubleshooting

```bash
journalctl -b -u var-mnt-phone.mount
dmesg | tail
```

- `Permission denied` on access: wrong username or password in the
  credentials file, or the user has no access to that share.
- `Permission denied` on write: the server gives that user read-only access.
- `Host is down` or a timeout: Tailscale is down or `media-server` is off
  (`tailscale status`).

## Removing it

```bash
sudo systemctl stop var-mnt-phone.automount var-mnt-phone.mount
sudo sed -i '\|/var/mnt/phone |d' /etc/fstab
sudo systemctl daemon-reload
sudo rm /etc/samba/credentials/media-server
sudo rmdir /var/mnt/phone
```
