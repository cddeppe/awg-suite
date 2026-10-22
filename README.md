# AWG Suite Installer

One script, one step: a complete **WireGuard + AmneziaWG + WGDashboard** stack on
Ubuntu/Debian (amd64 & arm64) — with systemd services and automatic weekly updates.

Everything is always built/fetched from **upstream**; this repo only hosts the installer.

| Component | Tools | Default port | Source |
|---|---|---|---|
| WireGuard | `wg`, `wg-quick` | UDP 51820 | distro package `wireguard-tools` |
| AmneziaWG | `awg`, `awg-quick`, `amneziawg-go` | UDP 42666 | [amnezia-vpn/amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go) · [amnezia-vpn/amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools) |
| WGDashboard | web UI | TCP 10086 | [WGDashboard/WGDashboard](https://github.com/WGDashboard/WGDashboard) |

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/cddeppe/amneziawg-go/master/awg-suite-installer.sh -o awg-suite-installer.sh
chmod +x awg-suite-installer.sh
sudo ./awg-suite-installer.sh install
```

Requires Ubuntu 22.04+ / Debian 12+ (amd64 or arm64), root, and internet access.

## Lifecycle

```bash
sudo ./awg-suite-installer.sh status      # versions, services, next auto-update
sudo ./awg-suite-installer.sh update      # update everything now
sudo ./awg-suite-installer.sh uninstall   # remove the suite (keeps tunnel configs)
```

`sudo ./awg-suite-installer.sh help` lists all options (ports, version pins,
`--no-dashboard`, `--purge`, ...).

## Automatic updates

`install` enables `awg-suite-update.timer`: every Sunday ~04:00 (±45 min) it
updates WireGuard (apt), AmneziaWG and WGDashboard — **and the installer itself,
from this repo's `master` branch**. Missed runs catch up after downtime
(`Persistent=true`). Logs: `journalctl -u awg-suite-update.service`.

## After install

- Dashboard: `http://<server-ip>:10086` — default login `admin` / `admin` (change it!)
- Starter configs: `/etc/wireguard/wg0.conf` (UDP 51820) and
  `/etc/amnezia/amneziawg/awg0.conf` (UDP 42666) — existing files are never overwritten.
- `uninstall` keeps tunnel configs and backs up the dashboard DB to
  `/var/backups/awg-suite`; add `--purge` to remove everything.
