# Libvirt VM has no internet (Fedora Atomic / ublue + Docker)

> **Now baked into the image.** `build.sh` ships and enables
> `libvirt-docker-forward.service` (the "Permanent fix" below), so a fresh
> sericea-main install handles this automatically. This doc is kept as the
> rationale + diagnostics for the rule, and for systems that predate the fix.

## Symptom

A VM managed by virt-manager (libvirt default NAT network, `virbr0`) can reach
the host (`192.168.122.1`) but cannot ping external addresses like `8.8.8.8`
or resolve DNS.

## Root cause

Docker sets the iptables `FORWARD` chain default policy to `DROP` and relies
on its own chains (`DOCKER-USER`, `DOCKER-FORWARD`) to selectively accept
traffic. Libvirt's NAT forwarding for `virbr0` → physical interface is not
covered by those chains, so VM traffic gets dropped.

Verify with:

```bash
sudo iptables -L FORWARD -n -v --line-numbers
```

If the header reads `Chain FORWARD (policy DROP ... packets)` with a large
packet counter, this is the issue.

## Quick test (non-persistent)

```bash
sudo iptables -P FORWARD ACCEPT
```

Then ping from the VM. If internet works, confirmed.

Setting policy to `ACCEPT` globally removes Docker's inter-container isolation,
so don't leave it this way.

## Permanent fix

Docker guarantees it won't touch rules in the `DOCKER-USER` chain (first jump
in `FORWARD`). Put explicit accept rules for `virbr0` there via a systemd
oneshot service so they re-apply on every boot after Docker starts.

Create `/etc/systemd/system/libvirt-docker-forward.service`:

```ini
[Unit]
Description=Allow libvirt VMs through Docker FORWARD chain
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/iptables -I DOCKER-USER -i virbr0 -j ACCEPT
ExecStart=/usr/sbin/iptables -I DOCKER-USER -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now libvirt-docker-forward.service
```

The inbound rule is conntrack-limited to `RELATED,ESTABLISHED`, so it only
permits reply packets — it does not expose VMs to unsolicited inbound traffic.

## Useful diagnostics

```bash
# Which VMs/networks are running under the system connection
virsh -c qemu:///system list --all
virsh -c qemu:///system net-list --all

# IP forwarding enabled?
cat /proc/sys/net/ipv4/ip_forward    # must be 1

# Libvirt's own NAT counters (should increment as VM sends traffic out)
sudo nft -n -a list table ip libvirt_network

# Where packets actually appear
sudo tcpdump -ni virbr0 icmp          # packets from VM
sudo tcpdump -ni wlp1s0 icmp          # packets after NAT on physical iface

# Docker FORWARD policy and counters
sudo iptables -L FORWARD -n -v --line-numbers
```

Pattern: packets visible on `virbr0` but absent on the physical interface =
forwarding is being dropped on the host (almost always the Docker FORWARD
DROP policy on this setup).

## Other things ruled out in the original debug session

- `firewalld` libvirt zone needed `masquerade` and `forward` enabled, plus a
  `libvirt-nat-out` policy from zone `libvirt` to `ANY` — all configured but
  were *not* the root cause here.
- `net.ipv4.ip_forward` was already `1`.
- SELinux was not denying (`ausearch -m AVC -ts recent` empty).
- No stale `docker-bridges` nftables tables lingering.

The smoking gun was the `FORWARD (policy DROP)` line with a matching packet
counter.
