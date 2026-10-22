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

Already have servers with WG/AWG/WGDashboard installed "by hand"? Just run the
installer. It scans for anything that differs from the canonical layout and,
since v1.0.5, **adopts it automatically** — full backups to
`/var/backups/awg-suite/pre-adopt-<date>/` first, nothing is deleted:

- a **live foreign WGDashboard** (one with its own systemd unit) is relocated
  to `/opt/wgdashboard` under `wgdashboard.service` — its database (peers,
  logins, settings) moves with it;
- **AWG-style configs stranded in `/etc/wireguard`** move to
  `/etc/amnezia/amneziawg` and run via `awg-quick@` units;
- **wg/awg binaries under `/usr/local`** that shadow the suite's `/usr/bin`
  versions are retired (PATH order makes them win — this bites silently);
- a tunnel that is **already up but not owned by systemd** is taken over with
  a brief restart under the suite's unit;
- starter tunnels are **not seeded** onto servers that already run their own
  tunnels, and an unused (peer-less) starter whose subnet collides with an
  existing tunnel is retired.

To scan without adopting: `sudo awg-suite install --no-adopt` (or check
`sudo awg-suite status`). The `--adopt-dashboard-from <path>`,
`--adopt-awg-configs` and `--adopt-clean-path` flags remain as explicit
overrides — passing any of them disables the automatic pass, so only what you
named is touched.

After adoption, every server has the identical layout — binaries in
`/usr/bin`, configs in `/etc/wireguard` + `/etc/amnezia/amneziawg`, dashboard
in `/opt/wgdashboard`, the same systemd units and the same weekly
auto-update. Existing VPN clients are unaffected: keys and ports are
preserved, tunnels just restart for a few seconds during the move. The
dashboard port/bind is standardized to the suite defaults (10086 / 0.0.0.0)
during adoption — override with `--dashboard-port` / `--dashboard-bind` if you
need to keep an old value.

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
