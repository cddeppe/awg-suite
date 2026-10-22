# awg-suite

One script, one step: a complete **WireGuard + AmneziaWG + WGDashboard** stack on
Ubuntu/Debian (amd64 & arm64) — systemd services, weekly auto-updates, always
built from **upstream** sources.

| Component | Tools | Default port | Source |
|---|---|---|---|
| WireGuard | `wg`, `wg-quick` | UDP 51820 | distro package `wireguard-tools` |
| AmneziaWG | `awg`, `awg-quick`, `amneziawg-go` | UDP 42666 | [amnezia-vpn/amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go) · [amnezia-vpn/amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools) |
| WGDashboard | web UI | TCP 10086 | [WGDashboard/WGDashboard](https://github.com/WGDashboard/WGDashboard) |

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/cddeppe/awg-suite/master/awg-suite-installer.sh | sudo bash
```

No command needed — a bare piped invocation installs. To pass options through
the pipe, use `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/cddeppe/awg-suite/master/awg-suite-installer.sh | sudo bash -s -- --dashboard-port 8080
```

Requires Ubuntu 22.04+ / Debian 12+ (amd64 or arm64), root, and internet access.
Everything — dependencies, Go toolchain, builds, services, starter configs — is
handled automatically; re-running is safe (idempotent).

## Lifecycle

```bash
sudo ./awg-suite-installer.sh status      # versions, services, next auto-update
sudo ./awg-suite-installer.sh update      # update everything now
sudo ./awg-suite-installer.sh uninstall   # remove the suite (keeps tunnel configs)
```

`sudo ./awg-suite-installer.sh help` lists all options (ports, version pins,
`--no-dashboard`, `--purge`, ...).

## Adopting existing servers

Already have servers with WG/AWG/WGDashboard installed "by hand"? `install`
and `status` automatically **scan** for anything that differs from the
canonical layout and report it — without changing anything. Then migrate with
the `--adopt-*` flags (every move is backed up to
`/var/backups/awg-suite/pre-adopt-<date>/` first; nothing is deleted):

```bash
# 1. see what would be adopted (read-only)
sudo awg-suite status

# 2. adopt an existing WGDashboard checkout - its database (peers, logins,
#    settings) moves with it; it gets relocated to /opt/wgdashboard and is
#    served by wgdashboard.service
sudo awg-suite install --adopt-dashboard-from /root/wgdashboard

# 3. move AWG-style configs that live in /etc/wireguard to
#    /etc/amnezia/amneziawg (run by awg-quick@ units)
sudo awg-suite install --adopt-awg-configs

# 4. remove old wg/awg binaries under /usr/local that shadow the suite's
#    /usr/bin versions (PATH order makes them win - this bites silently)
sudo awg-suite install --adopt-clean-path
```

After adoption, every server has the identical layout — binaries in
`/usr/bin`, configs in `/etc/wireguard` + `/etc/amnezia/amneziawg`, dashboard
in `/opt/wgdashboard`, the same systemd units and the same weekly
auto-update. Existing VPN clients are unaffected: keys and ports are
preserved, tunnels just restart for a few seconds during the move. The
dashboard port/bind is standardized to the suite defaults (10086 / 0.0.0.0)
during adoption — override with `--dashboard-port` / `--dashboard-bind` if
you need to keep an old value.

## Automatic updates

`install` enables `awg-suite-update.timer`: every Sunday ~04:00 (±45 min) it
updates WireGuard (apt), AmneziaWG and WGDashboard — **and the installer itself,
from this repo's `master` branch**. Missed runs catch up after downtime
(`Persistent=true`). Logs: `journalctl -u awg-suite-update.service`.

## After install

- Dashboard: `http://<server-ip>:10086` — default login `admin` / `admin` (change it!)
- Starter configs: `/etc/wireguard/wg0.conf` (UDP 51820) and
  `/etc/amnezia/amneziawg/awg0.conf` (UDP 42666) — existing files are never overwritten
  (re-running the installer does auto-repair seeds from older installer versions,
  e.g. the invalid AWG `H1`–`H4` values written before v1.0.3).
- `uninstall` keeps tunnel configs and backs up the dashboard DB to
  `/var/backups/awg-suite`; add `--purge` to remove everything.
