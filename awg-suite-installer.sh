#!/usr/bin/env bash
# =============================================================================
#  awg-suite-installer.sh
#
#  One-step installer / updater / uninstaller for the full VPN suite:
#
#    1. WireGuard          (wg + wg-quick, systemd wg-quick@.service)
#    2. AmneziaWG          (awg + awg-quick + amneziawg-go userspace backend,
#                          awg-quick@.service, /etc/amnezia/amneziawg)
#    3. WGDashboard        (web UI, systemd wgdashboard.service)
#
#  Everything is pulled from the UPSTREAM projects (never from a fork):
#    - https://github.com/amnezia-vpn/amneziawg-go
#    - https://github.com/amnezia-vpn/amneziawg-tools
#    - https://github.com/WGDashboard/WGDashboard
#    - https://go.dev  (Go toolchain, only when the distro Go is too old)
#
#  Supported platforms : Debian 12/13+, Ubuntu 22.04/24.04+ (amd64, arm64)
#                        (older releases work with --no-dashboard)
#
#  Usage:
#    sudo ./awg-suite-installer.sh install   [options]   (default command)
#    sudo ./awg-suite-installer.sh update    [options]
#    sudo ./awg-suite-installer.sh uninstall [--purge] [--yes]
#    sudo ./awg-suite-installer.sh status    | help
#    curl -fsSL <raw-url> | sudo bash        (one-step install, no command)
#
#  Install options:
#    --dashboard-port N     WGDashboard HTTP port           (default 10086)
#    --dashboard-bind IP    WGDashboard bind address        (default 0.0.0.0)
#    --wg-port N            seeded WireGuard listen port    (default 51820)
#    --awg-port N           seeded AmneziaWG listen port    (default 42666)
#    --no-seed              do not create starter wg0/awg0 tunnel configs
#    --no-dashboard         skip WGDashboard (also lifts the OS version floor)
#    --no-adopt             scan for foreign installs but do not adopt them
#    --no-auto-update       do not install the weekly auto-update systemd timer
#    --awg-go-tag TAG       pin amneziawg-go to a specific upstream tag
#    --awg-tools-tag TAG    pin amneziawg-tools to a specific upstream tag
#    --dashboard-tag TAG    pin WGDashboard to a specific upstream tag
#    --go-version V         use a specific Go toolchain version (e.g. 1.27.3)
#    --yes                  assume yes everywhere (non-interactive)
#
#  Update options:
#    --force                rebuild/reinstall even when already up to date
#    --no-self-update       do not try to refresh the installed script itself
#    --auto                 internal: used by the systemd timer (quiet)
#
#  Uninstall options:
#    --purge                also delete tunnel configs, keys, dashboard data
#                           and apt packages installed by this script
#    --yes                  assume yes (skip confirmation for --purge)
#
#  WireGuard uses UDP 51820 (upstream default), AmneziaWG uses UDP 42666,
#  WGDashboard serves HTTP on TCP 10086. All three run as systemd services.
#
#  This script is idempotent: re-running "install" repairs / upgrades in place
#  and never touches existing tunnel configs or dashboard settings.
# =============================================================================
# AWG_SUITE_INSTALLER=1  (marker used by the self-update sanity check)
# shellcheck disable=SC2034
AWG_SUITE_INSTALLER=1
SCRIPT_VERSION="1.0.7"
#
# Changelog:
#   v1.0.4 - Adoption & standardization: 'install' and 'status' now scan for
#            pre-existing/foreign installs (WGDashboard in other locations,
#            AWG configs in /etc/wireguard, wg/awg binaries in /usr/local
#            shadowing /usr/bin) and report them; new --adopt-dashboard-from
#            DIR, --adopt-awg-configs and --adopt-clean-path flags migrate
#            them into the canonical layout with full backups first
#            (/var/backups/awg-suite/pre-adopt-<date>/). Dashboard database
#            (logins/peers/settings) and tunnel configs/keys survive
#            adoption intact; existing VPN clients are unaffected.
#   v1.0.5 - Zero-touch standardization: adoption runs automatically when a
#            live foreign install is detected (--no-adopt restores the old
#            report-only behavior; any explicit --adopt-* flag also opts out
#            of the automatic pass). Starter tunnels are no longer seeded
#            onto servers that already run their own tunnels; an unused
#            (peer-less) starter whose subnet collides with an existing
#            tunnel is retired (backed up, unit disabled). A tunnel that is
#            already up but not owned by systemd is taken over with a brief
#            restart under the suite's unit. Dashboard start failures now
#            name the process that holds the port.
#   v1.0.6 - Port-collision awareness: a starter whose UDP listen port (not
#            just its subnet) is already bound by an existing tunnel is now
#            retired as well; starters whose interface exists are never
#            retired (left to the takeover logic). Tunnel start failures
#            name the interface/process that holds the colliding subnet or
#            UDP port. After dashboard adoption, the login hints correctly
#            point to the ORIGINAL credentials (restored database) instead
#            of admin/admin; a state marker remembers the adoption.
#   v1.0.7 - Update-safety after adoption: the dashboard dirty-tree check now
#            ignores runtime settings files (src/certbot.ini is tracked
#            upstream and is legitimately overwritten by adoption / the
#            dashboard itself), so version switches are no longer blocked;
#            those files are carried across tag switches. Adoption staging
#            is retired after use - a leftover staging dir from an older run
#            can never clobber the live dashboard database again. The
#            adopted-credentials hint now also fires from the persistent
#            state marker (adoptions performed by <= v1.0.5 are recognized
#            retroactively).

set -Eeuo pipefail

# ------------------------------------------------------------------ constants
REPO_AWG_GO="https://github.com/amnezia-vpn/amneziawg-go"
REPO_AWG_TOOLS="https://github.com/amnezia-vpn/amneziawg-tools"
REPO_DASHBOARD="https://github.com/WGDashboard/WGDashboard"

# Known-good upstream tags, used when git tag discovery is impossible
# (e.g. no network access to github.com).
AWG_GO_FALLBACK_TAG="v3.1.20260828"
AWG_TOOLS_FALLBACK_TAG="v3.1.20260812"
DASHBOARD_FALLBACK_TAG_PY312="v4.3.3"    # needs python >= 3.12, has AWG support
DASHBOARD_FALLBACK_TAG_PY310="v4.2.5"    # python 3.10 / 3.11

# Minimum Go toolchain required by amneziawg-go's go.mod
GO_MIN_VERSION="1.25.0"
# Pinned Go toolchain used when the distro Go is older than GO_MIN_VERSION.
GO_PINNED_VERSION="1.27.3"
GO_SHA256_AMD64="65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40"
GO_SHA256_ARM64="a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49"

# Where the installed copy of this script refreshes itself from.
# (Adjust if you host the script somewhere else.)
SELF_UPDATE_URL="https://raw.githubusercontent.com/cddeppe/awg-suite/master/awg-suite-installer.sh"

STATE_DIR="/var/lib/awg-suite"
LOG_DIR="/var/log/awg-suite"
LOCK_FILE="/var/lock/awg-suite-installer.lock"
SCRIPT_INSTALL_PATH="/usr/local/sbin/awg-suite-installer.sh"
SCRIPT_SYMLINK="/usr/local/sbin/awg-suite"
DASHBOARD_DIR="/opt/wgdashboard"
SYSCTL_FILE="/etc/sysctl.d/99-awg-suite.conf"
BACKUP_DIR="/var/backups/awg-suite"

WG_PORT_DEFAULT=51820
AWG_PORT_DEFAULT=42666
DASH_PORT_DEFAULT=10086
DASH_BIND_DEFAULT="0.0.0.0"

# APT packages required by the suite (installed only when missing).
BASE_PACKAGES=(
  ca-certificates curl git sudo
  build-essential pkg-config
  python3 python3-venv python3-pip iputils-ping net-tools
  iproute2 iptables
)

# ------------------------------------------------------------------ runtime vars
CMD=""
OPT_DASH_PORT="$DASH_PORT_DEFAULT"
OPT_DASH_BIND="$DASH_BIND_DEFAULT"
OPT_WG_PORT="$WG_PORT_DEFAULT"
OPT_AWG_PORT="$AWG_PORT_DEFAULT"
OPT_SEED=1
OPT_DASHBOARD=1
OPT_AUTO_UPDATE=1
OPT_AWG_GO_TAG=""
OPT_AWG_TOOLS_TAG=""
OPT_DASHBOARD_TAG=""
OPT_GO_VERSION="$GO_PINNED_VERSION"
OPT_FORCE=0
OPT_SELF_UPDATE=1
OPT_AUTO=0
OPT_PURGE=0
OPT_YES=0
OPT_ADOPT_DASH_FROM=""
OPT_ADOPT_AWG_CONF=0
OPT_ADOPT_CLEAN_PATH=0
OPT_NO_ADOPT=0
ADOPT_BACKUP=""
ADOPT_FINDINGS=0

# Environment (filled by detect_environment)
DISTRO_ID="" DISTRO_VERSION="" DISTRO_CODENAME=""
ARCH="" ARCH_GO=""
HAVE_SYSTEMD=0
PRIMARY_IP=""

# State (persisted to $STATE_DIR/state.env)
AWG_GO_TAG="" AWG_TOOLS_TAG="" DASHBOARD_TAG=""
GO_INSTALLED_BY_US=0 GO_VERSION_INSTALLED=""
SEEDED_WG=0 SEEDED_AWG=0
APT_PACKAGES=""
INSTALL_DATE=""

TMPDIR_AWG=""
LOG_FILE=""

# ------------------------------------------------------------------ pretty log
setup_colors() {
  if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_HDR=$'\033[1;36m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'
    C_ERR=$'\033[1;31m'; C_RUN=$'\033[0;37m'; C_RST=$'\033[0m'
  else
    C_HDR=""; C_OK=""; C_WARN=""; C_ERR=""; C_RUN=""; C_RST=""
  fi
}
log()  { printf '%s\n' "${C_RUN}[*]${C_RST} $*"; }
ok()   { printf '%s\n' "${C_OK}[+]${C_RST} $*"; }
warn() { printf '%s\n' "${C_WARN}[!]${C_RST} $*" >&2; }
err()  { printf '%s\n' "${C_ERR}[x]${C_RST} $*" >&2; }
die()  { err "$*"; err "Log saved to: ${LOG_FILE:-<none>}"; exit 1; }
hdr()  { printf '\n%s\n' "${C_HDR}=== $* ===${C_RST}"; }

on_error() {
  local exit_code=$? line=${1:-?}
  err "Script failed at line ${line} (exit code ${exit_code})."
  err "Full log: ${LOG_FILE:-<none>}"
  err "Fix the issue above and simply re-run the installer - it is idempotent."
}
trap 'on_error $LINENO' ERR

cleanup() { [ -n "$TMPDIR_AWG" ] && rm -rf "$TMPDIR_AWG" || true; }
trap cleanup EXIT

make_tmpdir() {
  # clean any previous scratch dir from an earlier step in this same run
  [ -n "$TMPDIR_AWG" ] && rm -rf "$TMPDIR_AWG"
  TMPDIR_AWG=$(mktemp -d /tmp/awg-suite.XXXXXX)
  chmod 700 "$TMPDIR_AWG"
}

# ------------------------------------------------------------------ utilities
ver_ge() { # ver_ge A B -> true if A >= B
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

ver_lt() { ! ver_ge "$1" "$2"; }

# Resolve this script's own source file. Fails when running from stdin
# (curl | sudo bash), where BASH_SOURCE[0] is "main" and no such file exists.
script_source_file() {
  local src="${BASH_SOURCE[0]:-}"
  if [ -n "$src" ] && [ -f "$src" ] && grep -q '^AWG_SUITE_INSTALLER=1' "$src" 2>/dev/null; then
    readlink -f "$src"
    return 0
  fi
  return 1
}

require_root() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if ! script_source_file >/dev/null 2>&1; then
    die "This script is being piped and must run as root:

    curl -fsSL ${SELF_UPDATE_URL} | sudo bash

or download it first and run:

    curl -fsSL ${SELF_UPDATE_URL} -o awg-suite-installer.sh
    sudo ./awg-suite-installer.sh install"
  fi
  if command -v sudo >/dev/null 2>&1; then
    log "Not running as root - re-executing through sudo..."
    exec sudo -E bash "$0" "$@"
  fi
  die "This script must run as root (try: sudo $0 ${CMD})."
}

acquire_lock() {
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    die "Another instance of the installer is already running."
  fi
}

setup_logging() {
  mkdir -p "$LOG_DIR" "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  LOG_FILE="$LOG_DIR/${CMD}.log"
  # simple size-based rotation
  if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt 1048576 ]; then
    mv -f "$LOG_FILE" "${LOG_FILE}.old"
  fi
  exec > >(tee -a "$LOG_FILE") 2>&1
  if [ "${OPT_AUTO:-0}" -eq 1 ]; then
    log "awg-suite-installer v${SCRIPT_VERSION} - command: ${CMD} (auto/timer mode)"
  else
    log "awg-suite-installer v${SCRIPT_VERSION} - command: ${CMD}"
  fi
  log "Log file: ${LOG_FILE}"
}

have_systemd() { [ "$HAVE_SYSTEMD" -eq 1 ]; }

sysdo() { # systemctl wrapper that degrades gracefully (e.g. containers)
  if have_systemd; then
    systemctl "$@"
  else
    log "(skipping: systemctl $* - systemd not running)"
  fi
}

detect_environment() {
  hdr "Detecting environment"

  if [ ! -f /etc/os-release ]; then
    die "No /etc/os-release found - this installer targets Debian/Ubuntu only."
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-}"
  DISTRO_VERSION="${VERSION_ID:-}"
  DISTRO_CODENAME="${VERSION_CODENAME:-}"

  case "$DISTRO_ID" in
    ubuntu) ;;
    debian) ;;
    raspbian) DISTRO_ID=debian ;;
    *)
      if grep -qiE 'debian|ubuntu' <<<"${ID_LIKE:-}"; then
        warn "Untested derivative '${ID}' (debian/ubuntu compatible) - continuing."
      else
        die "Unsupported distribution '${DISTRO_ID}'. This installer targets Debian/Ubuntu."
      fi
      ;;
  esac

  case "$(uname -m)" in
    x86_64)  ARCH=amd64;  ARCH_GO=amd64 ;;
    aarch64) ARCH=arm64;  ARCH_GO=arm64 ;;
    armv7l|armv6l)
      die "32-bit ARM (armv7/armv6) is not supported. Use a 64-bit OS (aarch64)." ;;
    *)
      die "Unsupported architecture: $(uname -m) (supported: x86_64/amd64, aarch64/arm64)." ;;
  esac

  [ -d /run/systemd/system ] && HAVE_SYSTEMD=1 || HAVE_SYSTEMD=0

  PRIMARY_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
  [ -n "$PRIMARY_IP" ] || PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "$PRIMARY_IP" ] || PRIMARY_IP="127.0.0.1"

  local major="${DISTRO_VERSION%%.*}"
  case "$DISTRO_ID" in
    debian)  [ "$major" -lt 12 ] && DISTRO_TOO_OLD=1 || DISTRO_TOO_OLD=0 ;;
    ubuntu)  [ "$major" -lt 22 ] && DISTRO_TOO_OLD=1 || DISTRO_TOO_OLD=0 ;;
    *)       DISTRO_TOO_OLD=0 ;;
  esac
  if [ "${DISTRO_TOO_OLD:-0}" -eq 1 ]; then
    if [ "$OPT_DASHBOARD" -eq 1 ]; then
      die "${DISTRO_ID^} ${DISTRO_VERSION} is too old for WGDashboard (needs Python >= 3.10).
Re-run with --no-dashboard to install WireGuard + AmneziaWG only, or upgrade the OS."
    fi
    warn "${DISTRO_ID^} ${DISTRO_VERSION} is old - installing WireGuard + AmneziaWG only."
  fi

  if [ ! -e /dev/net/tun ]; then
    warn "/dev/net/tun is missing (container/LXC?). Tunnels are installed but"
    warn "cannot run here. Tunnels will start automatically once /dev/net/tun exists."
  fi

  local free_mb
  free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
  if [ "${free_mb:-0}" -lt 2048 ]; then
    warn "Less than 2GB free disk space on / - the build may fail."
  fi

  ok "OS: ${PRETTY_NAME:-$DISTRO_ID $DISTRO_VERSION} (${DISTRO_CODENAME:-n/a}) | arch: ${ARCH} | systemd: ${HAVE_SYSTEMD} | ip: ${PRIMARY_IP}"
}

# ------------------------------------------------------------------ state I/O
save_state() {
  mkdir -p "$STATE_DIR"
  cat > "$STATE_DIR/state.env" <<EOF
# Managed by awg-suite-installer.sh - do not edit while the installer runs.
AWG_GO_TAG='${AWG_GO_TAG}'
AWG_TOOLS_TAG='${AWG_TOOLS_TAG}'
DASHBOARD_TAG='${DASHBOARD_TAG}'
GO_INSTALLED_BY_US=${GO_INSTALLED_BY_US}
GO_VERSION_INSTALLED='${GO_VERSION_INSTALLED}'
SEEDED_WG=${SEEDED_WG}
SEEDED_AWG=${SEEDED_AWG}
APT_PACKAGES='${APT_PACKAGES}'
INSTALL_DATE='${INSTALL_DATE}'
DASH_PORT='${OPT_DASH_PORT}'
DASH_BIND='${OPT_DASH_BIND}'
WG_PORT='${OPT_WG_PORT}'
AWG_PORT='${OPT_AWG_PORT}'
SCRIPT_VERSION='${SCRIPT_VERSION}'
EOF
  chmod 600 "$STATE_DIR/state.env"
}

load_state() {
  if [ -f "$STATE_DIR/state.env" ]; then
    # shellcheck disable=SC1090
    . "$STATE_DIR/state.env"
    [ -n "${DASH_PORT:-}" ] && OPT_DASH_PORT="$DASH_PORT"
    [ -n "${DASH_BIND:-}" ] && OPT_DASH_BIND="$DASH_BIND"
    [ -n "${WG_PORT:-}" ] && OPT_WG_PORT="$WG_PORT"
    [ -n "${AWG_PORT:-}" ] && OPT_AWG_PORT="$AWG_PORT"
  fi
}

require_installed() {
  if [ ! -f "$STATE_DIR/state.env" ]; then
    die "The suite is not installed (no state in ${STATE_DIR}). Run '${0} install' first."
  fi
}

# ------------------------------------------------------------------ upstream version discovery
# Uses 'git ls-remote' (no GitHub API - immune to api.github.com rate limits).
git_latest_tag() {
  local repo="$1" filter="${2:-}" tag="" attempt
  for attempt in 1 2 3; do
    tag=$(timeout 30 git ls-remote --tags "$repo" 2>/dev/null \
            | awk -F'\t' '$1 ~ /^[0-9a-f]+$/ && $2 ~ /^refs\/tags\// {sub(/^refs\/tags\//, "", $2); print $2}' \
            | sed 's/\^{}$//' | sort -u \
            | grep -E '^v?[0-9]+(\.[0-9]+)+' \
            | grep -viE '(rc|alpha|beta|dev|test)' \
            || true)
    if [ -n "$tag" ]; then
      if [ -n "$filter" ]; then
        tag=$(grep -E "$filter" <<<"$tag" || true)
      fi
      tag=$(sort -V <<<"$tag" | tail -n1)
      [ -n "$tag" ] && { printf '%s\n' "$tag"; return 0; }
    fi
    warn "Tag discovery for ${repo} failed (attempt ${attempt}/3) - retrying..."
    sleep 2
  done
  return 1
}

latest_awg_go_tag()   { git_latest_tag "$REPO_AWG_GO" || printf '%s\n' "$AWG_GO_FALLBACK_TAG"; }
latest_awg_tools_tag(){ git_latest_tag "$REPO_AWG_TOOLS" || printf '%s\n' "$AWG_TOOLS_FALLBACK_TAG"; }

# WGDashboard tag depends on the available python3 (v4.3+ requires >= 3.12)
latest_dashboard_tag() {
  local pyver
  pyver=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo 0)
  if ver_ge "$pyver" 3.12; then
    git_latest_tag "$REPO_DASHBOARD" || printf '%s\n' "$DASHBOARD_FALLBACK_TAG_PY312"
  else
    git_latest_tag "$REPO_DASHBOARD" '^v4\.2\.' || printf '%s\n' "$DASHBOARD_FALLBACK_TAG_PY310"
  fi
}

# ------------------------------------------------------------------ apt helpers
apt_get() {
  # dpkg lock timeout: timer runs may collide with unattended-upgrades
  local lock_to=120
  [ "${OPT_AUTO:-0}" -eq 1 ] && lock_to=600
  DEBIAN_FRONTEND=noninteractive apt-get -y -q \
    -o Dpkg::Lock::Timeout=${lock_to} \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew \
    "$@"
}

apt_update_retry() {
  local attempt
  for attempt in 1 2; do
    apt_get update >/dev/null 2>&1 && { ok "apt package index updated."; return 0; }
    warn "apt-get update failed (attempt ${attempt}/2) - retrying..."
    sleep 3
  done
  # not fatal: packages may still be resolvable from cache
  warn "apt-get update keeps failing - continuing with the cached package index."
  return 0
}

ensure_packages() {
  local to_install=() p
  for p in "$@"; do
    if ! dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null | grep -q '^ii'; then
      to_install+=("$p")
    fi
  done
  [ "${#to_install[@]}" -eq 0 ] && return 0
  log "Installing apt packages: ${to_install[*]}"
  apt_get install "${to_install[@]}" >/dev/null
  for p in "${to_install[@]}"; do
    case " $APT_PACKAGES " in *" $p "*) ;; *) APT_PACKAGES="${APT_PACKAGES:+$APT_PACKAGES }$p" ;; esac
  done
  save_state
}

# ------------------------------------------------------------------ Go toolchain
go_version_of() { # go_version_of <bindir>
  local g="${1%/}/go"
  [ -x "$g" ] || return 1
  "$g" version 2>/dev/null | awk '{print $3}' | sed 's/^go//' || true
}

ensure_go() {
  hdr "Ensuring Go toolchain (>= ${GO_MIN_VERSION})"

  local sysver
  sysver=$(go_version_of /usr/bin 2>/dev/null || go_version_of /usr/local/bin 2>/dev/null || true)
  if [ -n "$sysver" ] && ver_ge "$sysver" "$GO_MIN_VERSION"; then
    ok "Using system Go ${sysver} (>= ${GO_MIN_VERSION})."
    GO_INSTALLED_BY_US=0
    export PATH="/usr/bin:/usr/local/bin:$PATH"
    return 0
  fi
  [ -n "$sysver" ] && warn "System Go ${sysver} is older than ${GO_MIN_VERSION} - installing pinned toolchain."

  local want="$OPT_GO_VERSION" sha=""
  if [ "$want" = "$GO_PINNED_VERSION" ]; then
    case "$ARCH_GO" in
      amd64) sha="$GO_SHA256_AMD64" ;;
      arm64) sha="$GO_SHA256_ARM64" ;;
    esac
  else
    log "Querying go.dev for sha256 of go${want}..."
    sha=$(curl -fsSL --retry 3 --connect-timeout 15 "https://go.dev/dl/?mode=json&include=all" \
          | python3 -c "
import json,sys
arch='${ARCH_GO}'
ver='go${want}'
for rel in json.load(sys.stdin):
    if rel['version']==ver:
        for f in rel['files']:
            if f['os']=='linux' and f['arch']==arch and f['kind']=='archive':
                print(f['sha256']); break
        break
" 2>/dev/null || true)
    [ -n "$sha" ] || die "Could not fetch sha256 for Go ${want} from go.dev - refusing to install unverified."
  fi

  local tgz="${TMPDIR_AWG}/go${want}.linux-${ARCH_GO}.tar.gz"
  log "Downloading Go ${want} for ${ARCH_GO}..."
  curl -fL --retry 3 --connect-timeout 15 -o "$tgz" "https://go.dev/dl/go${want}.linux-${ARCH_GO}.tar.gz"

  log "Verifying sha256..."
  echo "${sha}  ${tgz}" | sha256sum -c - >/dev/null || die "Go tarball checksum mismatch - aborting."

  log "Installing Go ${want} to /usr/local/go..."
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tgz"
  GO_INSTALLED_BY_US=1
  GO_VERSION_INSTALLED="$want"
  save_state
  export PATH="/usr/local/go/bin:$PATH"
  command -v go >/dev/null || die "Go was installed but is not usable."
  ok "Go $(go version | awk '{print $3}') installed (managed by this script)."
}

# ------------------------------------------------------------------ WireGuard
install_wireguard() {
  hdr "WireGuard (wg / wg-quick via apt)"
  ensure_packages wireguard-tools
  mkdir -p /etc/wireguard
  chmod 700 /etc/wireguard
  ok "WireGuard tools $(wg --version 2>/dev/null || echo 'installed')."
  ok "Tunnel config directory: /etc/wireguard"
}

# ------------------------------------------------------------------ amneziawg-go
install_awg_go() { # $1 = tag
  local tag="$1"
  hdr "AmneziaWG userspace backend: amneziawg-go ${tag}"

  if [ "$OPT_FORCE" -eq 0 ] && [ "$AWG_GO_TAG" = "$tag" ] && [ -x /usr/bin/amneziawg-go ]; then
    ok "amneziawg-go ${tag} already installed - nothing to do."
    return 0
  fi

  ensure_go
  make_tmpdir

  local src="${TMPDIR_AWG}/amneziawg-go"
  log "Cloning ${REPO_AWG_GO} (tag ${tag})..."
  git clone -q --depth 1 --branch "$tag" "$REPO_AWG_GO" "$src"

  log "Building amneziawg-go (this compiles the Go userspace WireGuard implementation)..."
  make -C "$src" >/dev/null

  install -m 0755 "$src/amneziawg-go" /usr/bin/amneziawg-go
  AWG_GO_TAG="$tag"
  save_state

  ok "Installed /usr/bin/amneziawg-go (${tag})."
  log "Version string: $(/usr/bin/amneziawg-go --version 2>/dev/null || echo 'n/a')"
}

# ------------------------------------------------------------------ amneziawg-tools
install_awg_tools() { # $1 = tag
  local tag="$1"
  hdr "AmneziaWG tools: awg / awg-quick ${tag}"

  if [ "$OPT_FORCE" -eq 0 ] && [ "$AWG_TOOLS_TAG" = "$tag" ] && [ -x /usr/bin/awg ] && [ -x /usr/bin/awg-quick ]; then
    ok "amneziawg-tools ${tag} already installed - nothing to do."
    return 0
  fi

  make_tmpdir
  local src="${TMPDIR_AWG}/amneziawg-tools"
  log "Cloning ${REPO_AWG_TOOLS} (tag ${tag})..."
  git clone -q --depth 1 --branch "$tag" "$REPO_AWG_TOOLS" "$src"

  log "Building awg (C userspace tool)..."
  make -C "$src/src" >/dev/null

  log "Installing awg, awg-quick, man pages, completions, systemd units..."
  make -C "$src/src" install >/dev/null

  mkdir -p /etc/amnezia/amneziawg
  chmod 700 /etc/amnezia/amneziawg

  AWG_TOOLS_TAG="$tag"
  save_state

  ok "Installed: $(command -v awg), $(command -v awg-quick)"
  ok "Tunnel config directory: /etc/amnezia/amneziawg"
  if [ -f /usr/lib/systemd/system/awg-quick@.service ] || [ -f /lib/systemd/system/awg-quick@.service ]; then
    ok "Systemd unit awg-quick@.service installed."
  else
    warn "awg-quick@.service was not installed (no systemd unit dir?) - tunnels can still be started manually."
  fi
}

# ------------------------------------------------------------------ WGDashboard
dashboard_target_tag() {
  if [ -n "$OPT_DASHBOARD_TAG" ]; then
    printf '%s\n' "$OPT_DASHBOARD_TAG"
  else
    latest_dashboard_tag
  fi
}

# ------------------------------------------------------------------ adoption (v1.0.4)
# Bring servers with pre-existing / non-standard installs under the suite's
# canonical layout. Detection is always on (report-only, no changes); the
# actual moves require explicit --adopt-* flags and are fully backed up.

WG_CONF_DIR="/etc/wireguard"
AWG_CONF_DIR="/etc/amnezia/amneziawg"
SHADOW_BIN_DIRS_DEFAULT="/usr/local/bin /usr/local/sbin"
SYSTEMD_UNIT_DIR_DEFAULT="/etc/systemd/system"
FOREIGN_DASH_CANDIDATES_DEFAULT="${DASHBOARD_DIR}/../WGDashboard /opt/wg-dashboard /root/wgdashboard /root/WGDashboard /srv/wgdashboard /usr/local/wgdashboard"
ADOPTED_AWG_UNITS=""   # awg config names adopted this run (enabled at the end of install)

looks_like_wgdashboard_dir() { [ -f "$1/src/wgd.sh" ]; }

unit_files_referencing_wgd() { # prints unit files whose ExecStart runs wgd.sh
  local d f
  for d in $SYSTEMD_UNIT_DIR_DEFAULT /usr/lib/systemd/system; do
    for f in "$d"/*.service; do
      [ -f "$f" ] || continue
      if grep -q 'wgd\.sh' "$f" 2>/dev/null; then
        printf '%s\n' "$f"
      fi
    done
  done
  return 0
}

unit_files_referencing_awg_conf() { # $1 = conf file path
  local d f
  for d in $SYSTEMD_UNIT_DIR_DEFAULT /usr/lib/systemd/system; do
    for f in "$d"/*.service; do
      [ -f "$f" ] || continue
      if grep -q 'awg-quick' "$f" 2>/dev/null && grep -qF "$1" "$f" 2>/dev/null; then
        printf '%s\n' "$f"
      fi
    done
  done
  return 0
}

find_foreign_dashboards() { # prints "path<TAB>unitfile" (ours excluded)
  local p f root
  for p in $FOREIGN_DASH_CANDIDATES_DEFAULT; do
    [ -d "$p" ] || continue
    looks_like_wgdashboard_dir "$p" || continue
    printf '%s\t\n' "$p"
  done
  # a non-git copy at our own canonical path is foreign too
  if [ -d "$DASHBOARD_DIR" ] && [ ! -d "$DASHBOARD_DIR/.git" ] && looks_like_wgdashboard_dir "$DASHBOARD_DIR"; then
    printf '%s\t\n' "$DASHBOARD_DIR"
  fi
  # dashboards discovered via their systemd unit (any path)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    root=$(sed -n -E -e 's#^ExecStart=.*[[:space:]](/[^[:space:]]*)/src/wgd\.sh.*#\1#p' \
                     -e 's#^WorkingDirectory=(/[^[:space:]]*)/src$#\1#p' "$f" | head -1)
    [ -n "$root" ] || continue
    [ -d "$root" ] || continue
    # skip our own managed checkout + our canonical unit
    if [ "$f" = "${SYSTEMD_UNIT_DIR_DEFAULT}/wgdashboard.service" ] && [ "$root" = "$DASHBOARD_DIR" ] && [ -d "$DASHBOARD_DIR/.git" ]; then
      continue
    fi
    printf '%s\t%s\n' "$root" "$f"
  done < <(unit_files_referencing_wgd)
  return 0
}

find_awg_configs_in_wg_dir() { # AWG-style configs stranded in /etc/wireguard
  local f
  for f in "$WG_CONF_DIR"/*.conf; do
    [ -f "$f" ] || continue
    if grep -qE '^[[:space:]]*(Jc|Jmin|Jmax|S1|S2|S3|S4|H[1-4])[[:space:]]*=' "$f" 2>/dev/null; then
      printf '%s\n' "$f"
    fi
  done
  return 0
}

find_shadow_binaries() { # wg/awg binaries in /usr/local that shadow /usr/bin
  local d b
  for d in $SHADOW_BIN_DIRS_DEFAULT; do
    for b in wg wg-quick awg awg-quick amneziawg-go; do
      if [ -e "$d/$b" ]; then
        printf '%s\n' "$d/$b"
      fi
    done
  done
  return 0
}

adoption_report() { # read-only scan; sets ADOPT_FINDINGS
  ADOPT_FINDINGS=0
  local dashes p unit uname awgconfs f shadows
  dashes=$(find_foreign_dashboards | sort -u)
  if [ -n "$dashes" ]; then
    warn "Foreign WGDashboard installation(s) found:"
    while IFS=$'\t' read -r p unit; do
      [ -n "$p" ] || continue
      uname=""
      [ -n "$unit" ] && uname="  (unit: $(basename "$unit"))"
      printf '      %s%s\n' "$p" "$uname"
    done <<<"$dashes"
    log "  -> standardize with: --adopt-dashboard-from <path>"
    ADOPT_FINDINGS=$((ADOPT_FINDINGS+1))
  fi
  awgconfs=$(find_awg_configs_in_wg_dir)
  if [ -n "$awgconfs" ]; then
    warn "AmneziaWG-style configs inside ${WG_CONF_DIR} (they belong in ${AWG_CONF_DIR}):"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf '      %s\n' "$f"
    done <<<"$awgconfs"
    log "  -> standardize with: --adopt-awg-configs"
    ADOPT_FINDINGS=$((ADOPT_FINDINGS+1))
  fi
  shadows=$(find_shadow_binaries)
  if [ -n "$shadows" ]; then
    warn "wg/awg binaries under /usr/local shadow the suite's /usr/bin versions (PATH order):"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf '      %s\n' "$f"
    done <<<"$shadows"
    log "  -> standardize with: --adopt-clean-path"
    ADOPT_FINDINGS=$((ADOPT_FINDINGS+1))
  fi
  if [ -d /sys/module/amneziawg ]; then
    log "AmneziaWG kernel module is loaded - tunnels may use the kernel path;"
    log "the suite's userspace backend is installed alongside it (same configs)."
  fi
  if [ "$ADOPT_FINDINGS" -eq 0 ]; then
    ok "No foreign WG/AWG/dashboard artifacts detected - layout already canonical."
  fi
  return 0
}

pre_adopt_backup() {
  if [ -z "$ADOPT_BACKUP" ]; then
    ADOPT_BACKUP="${BACKUP_DIR}/pre-adopt-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$ADOPT_BACKUP"
    log "Adoption backup directory: ${ADOPT_BACKUP}"
  fi
  return 0
}

move_to_backup() { # $1=src path  $2=name inside the backup dir
  pre_adopt_backup
  if mv "$1" "$ADOPT_BACKUP/$2" 2>/dev/null; then
    return 0
  fi
  cp -a "$1" "$ADOPT_BACKUP/$2" && rm -rf "$1"
}

stop_and_retire_dashboard_units() { # retire every unit that runs wgd.sh
  local f base
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base=$(basename "$f")
    sysdo stop "$base" 2>/dev/null || true
    sysdo disable "$base" 2>/dev/null || true
    move_to_backup "$f" "$base"
    log "Retired old dashboard unit: ${base} (backed up; canonical unit reinstalled next)."
  done < <(unit_files_referencing_wgd)
  sysdo daemon-reload 2>/dev/null || true
  return 0
}

adopt_dashboard_from() { # $1 = existing WGDashboard checkout directory
  local dir="$1" bname staging item
  [ -d "$dir" ] || die "Adoption source '${dir}' does not exist."
  looks_like_wgdashboard_dir "$dir" || die "'${dir}' does not look like a WGDashboard checkout (no src/wgd.sh found)."
  [ "$OPT_DASHBOARD" -eq 1 ] || die "--adopt-dashboard-from needs the dashboard component (drop --no-dashboard)."

  pre_adopt_backup
  bname=$(basename "$dir")

  # whatever sits at the canonical path (managed checkout or foreign copy)
  # steps aside for the adopted dashboard
  if [ "$dir" != "$DASHBOARD_DIR" ] && [ -d "$DASHBOARD_DIR" ]; then
    warn "Existing ${DASHBOARD_DIR} found - backing it up; the adopted dashboard replaces it."
    sysdo stop wgdashboard.service 2>/dev/null || true
    move_to_backup "$DASHBOARD_DIR" "managed-wgdashboard"
  fi

  stop_and_retire_dashboard_units

  # stage the data that must survive: db (peers/logins/settings), ini, logs
  staging="${STATE_DIR}/adopt-dashboard-data"
  rm -rf "$staging"
  mkdir -p "$staging"
  for item in db log certbot.ini wg-dashboard.ini; do
    if [ -e "$dir/src/$item" ]; then
      cp -a "$dir/src/$item" "$staging/"
      log "Staged for restore: ${item}"
    fi
  done
  # v1.0.7: mark the staging as fresh so restore_adopted_dashboard_data()
  # knows it may overwrite the checkout contents (leftover staging from a
  # PREVIOUS run must never clobber the live database).
  ADOPT_STAGE_FRESH=1

  # move the whole old checkout into the adoption backup
  move_to_backup "$dir" "$bname"
  ok "Adopted dashboard from ${dir} (full original copy: ${ADOPT_BACKUP}/${bname})."
  ok "Its database/settings will be restored into ${DASHBOARD_DIR} during this run."
  return 0
}

restore_adopted_dashboard_data() { # called by install_dashboard before version checks
  local staging="${STATE_DIR}/adopt-dashboard-data" item ini old_port old_ip
  [ -d "$staging" ] || return 0
  [ -n "$(ls -A "$staging" 2>/dev/null)" ] || return 0
  # v1.0.7: staging left over from a PREVIOUS run (adoption completed, data
  # already restored back then) must never overwrite the live database,
  # which has kept evolving since. Only data staged in THIS run
  # (ADOPT_STAGE_FRESH, set by adopt_dashboard_from) is authoritative.
  # Either way: remember the adoption (persistent marker, so servers adopted
  # by older installer versions get correct credentials hints too) and
  # retire the staging so no future run repeats this.
  if [ "${ADOPT_STAGE_FRESH:-0}" -ne 1 ] && [ -e "${DASHBOARD_DIR}/src/db" ]; then
    ADOPTED_DASH_RESTORED=1
    touch "${STATE_DIR}/dashboard-adopted" 2>/dev/null || true
    rm -rf "$staging"
    ok "Previous dashboard adoption found - keeping the live database as is."
    ok "Adopted database active - log in with your ORIGINAL credentials (not admin/admin)."
    return 0
  fi
  for item in db log certbot.ini wg-dashboard.ini; do
    if [ -e "$staging/$item" ]; then
      rm -rf "${DASHBOARD_DIR}/src/$item"
      cp -a "$staging/$item" "${DASHBOARD_DIR}/src/"
      ok "Restored adopted dashboard ${item}."
    fi
  done
  rm -rf "$staging"
  # v1.0.6: remember the adoption so login hints point at the ORIGINAL
  # credentials (the restored database keeps the old accounts, not admin/admin)
  ADOPTED_DASH_RESTORED=1
  touch "${STATE_DIR}/dashboard-adopted" 2>/dev/null || true
  ok "Adopted database active - log in with your ORIGINAL credentials (not admin/admin)."
  # normalize ini port/bind to the values chosen for this install
  ini="${DASHBOARD_DIR}/src/wg-dashboard.ini"
  if [ -f "$ini" ]; then
    old_port=$(sed -n 's/^app_port[[:space:]]*=[[:space:]]*//p' "$ini" | tail -1)
    old_ip=$(sed -n 's/^app_ip[[:space:]]*=[[:space:]]*//p' "$ini" | tail -1)
    if [ -n "$old_port" ] && [ "$old_port" != "$OPT_DASH_PORT" ]; then
      warn "Adopted dashboard port ${old_port} -> ${OPT_DASH_PORT} (standardizing; update bookmarks)."
      sed -i -E "s|^app_port[[:space:]]*=.*|app_port = ${OPT_DASH_PORT}|" "$ini"
    fi
    if [ -n "$old_ip" ] && [ "$old_ip" != "$OPT_DASH_BIND" ]; then
      warn "Adopted dashboard bind ${old_ip} -> ${OPT_DASH_BIND} (standardizing)."
      sed -i -E "s|^app_ip[[:space:]]*=.*|app_ip = ${OPT_DASH_BIND}|" "$ini"
    fi
  fi
  return 0
}

adopt_awg_configs() {
  local f name target moved=0 confs uf
  confs=$(find_awg_configs_in_wg_dir)
  if [ -z "$confs" ]; then
    ok "No AmneziaWG configs found in ${WG_CONF_DIR} - nothing to adopt."
    return 0
  fi
  pre_adopt_backup
  mkdir -p "$AWG_CONF_DIR"
  chmod 700 "$AWG_CONF_DIR" 2>/dev/null || true
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    name=$(basename "$f" .conf)
    target="${AWG_CONF_DIR}/${name}.conf"
    if [ -e "$target" ]; then
      warn "${target} already exists - keeping it; ${f} left in place (resolve manually)."
      continue
    fi
    # retire custom units that run awg-quick on the old path
    while IFS= read -r uf; do
      [ -n "$uf" ] || continue
      sysdo stop "$(basename "$uf")" 2>/dev/null || true
      sysdo disable "$(basename "$uf")" 2>/dev/null || true
      move_to_backup "$uf" "$(basename "$uf")"
      log "Retired custom unit $(basename "$uf") (backed up)."
    done < <(unit_files_referencing_awg_conf "$f")
    sysdo daemon-reload 2>/dev/null || true
    # retire any (failing) wg-quick unit for this name, then move the config
    sysdo disable "wg-quick@${name}.service" 2>/dev/null || true
    sysdo reset-failed "wg-quick@${name}.service" 2>/dev/null || true
    cp -p "$f" "$target"
    chmod 600 "$target"
    move_to_backup "$f" "wg-conf-${name}.conf"
    if sysdo start "awg-quick@${name}.service" >/dev/null 2>&1; then
      sysdo enable "awg-quick@${name}.service" >/dev/null 2>&1 || true
      ok "Adopted ${name}.conf into ${AWG_CONF_DIR}; started awg-quick@${name}."
    else
      sysdo enable "awg-quick@${name}.service" >/dev/null 2>&1 || true
      warn "Adopted ${name}.conf into ${AWG_CONF_DIR}; awg-quick@${name} not started"
      warn "yet - check: journalctl -u awg-quick@${name}.service -n 30 --no-pager"
    fi
    ADOPTED_AWG_UNITS="${ADOPTED_AWG_UNITS:+${ADOPTED_AWG_UNITS} }${name}"
    moved=$((moved+1))
  done <<<"$confs"
  if [ "$moved" -gt 0 ]; then
    ok "Adopted ${moved} AmneziaWG config(s) from ${WG_CONF_DIR} (originals in ${ADOPT_BACKUP})."
  fi
  return 0
}

adopt_clean_path() {
  local d b found=0
  pre_adopt_backup
  for d in $SHADOW_BIN_DIRS_DEFAULT; do
    [ -d "$d" ] || continue
    for b in wg wg-quick awg awg-quick amneziawg-go; do
      if [ -e "$d/$b" ]; then
        move_to_backup "$d/$b" "bin-${b}"
        found=$((found+1))
        warn "Removed shadowing binary ${d}/${b} (was overriding /usr/bin/${b} via PATH order)."
      fi
    done
  done
  hash -r 2>/dev/null || true
  if [ "$found" -gt 0 ]; then
    ok "Moved ${found} shadowing binary(ies) to ${ADOPT_BACKUP}."
  else
    ok "No shadowing wg/awg binaries under /usr/local - nothing to do."
  fi
  return 0
}

adopt_dashboards_auto() { # v1.0.5: adopt the live foreign dashboard, if any
  local picked="" p u n=0
  while IFS=$'\t' read -r p u; do
    [ -n "$p" ] || continue
    n=$((n+1))
    [ -n "$u" ] && picked="$p"   # a dashboard with its own systemd unit is live - prefer it
  done < <(find_foreign_dashboards)
  if [ -z "$picked" ]; then
    # nothing live out there - stale copies stay put (nothing urgent to fix)
    log "Foreign dashboard copy(ies) found without a systemd unit - left in place."
    log "Standardize manually with: awg-suite install --adopt-dashboard-from <path>"
    return 0
  fi
  log "Auto-adopting the live WGDashboard at ${picked} (database, peers and"
  log "logins are preserved; the full original is backed up)."
  adopt_dashboard_from "$picked"
  if [ "$n" -gt 1 ]; then
    warn "Multiple foreign WGDashboard installations found - adopted the live one (${picked})."
    warn "Others were left untouched; use --adopt-dashboard-from <path> to pick a different one."
  fi
  return 0
}

run_adoption() {
  hdr "Adoption scan (pre-existing installs)"
  adoption_report

  # v1.0.5: with no --adopt-* flags and no --no-adopt, adoption is automatic.
  local auto=0
  if [ "$OPT_NO_ADOPT" -ne 1 ] && [ -z "$OPT_ADOPT_DASH_FROM" ] \
     && [ "$OPT_ADOPT_AWG_CONF" -eq 0 ] && [ "$OPT_ADOPT_CLEAN_PATH" -eq 0 ] \
     && [ "$ADOPT_FINDINGS" -gt 0 ]; then
    auto=1
    log "Adoption is automatic: everything found above is standardized in this run"
    log "(full backups kept; pass --no-adopt to scan without adopting)."
  fi

  if [ -n "$OPT_ADOPT_DASH_FROM" ]; then
    adopt_dashboard_from "$OPT_ADOPT_DASH_FROM"
  elif [ "$auto" -eq 1 ] && [ "$OPT_DASHBOARD" -eq 1 ]; then
    adopt_dashboards_auto
  elif [ "$auto" -eq 1 ]; then
    log "Dashboard component disabled - foreign dashboards left as found."
  fi
  if [ "$OPT_ADOPT_AWG_CONF" -eq 1 ] || [ "$auto" -eq 1 ]; then
    adopt_awg_configs
  fi
  if [ "$OPT_ADOPT_CLEAN_PATH" -eq 1 ] || [ "$auto" -eq 1 ]; then
    adopt_clean_path
  fi
  return 0
}
# ------------------------------------------------------------------ end adoption

install_dashboard() { # $1 = tag
  local tag="$1"
  hdr "WGDashboard ${tag}"

  local pyver
  pyver=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo 0)
  if ! ver_ge "$pyver" 3.10; then
    die "WGDashboard needs Python >= 3.10 (found ${pyver}). Use --no-dashboard to skip it."
  fi
  if ver_lt "$pyver" 3.12 && [ "$tag" != "$(printf '%s' "$tag" | grep -E '^v4\.2\.' || true)" ]; then
    warn "Python ${pyver} < 3.12 - dashboard tags newer than v4.2.x may not be supported."
  fi

  local cloned_now=0
  if [ ! -d "$DASHBOARD_DIR/.git" ]; then
    if [ -d "$DASHBOARD_DIR" ]; then
      die "${DASHBOARD_DIR} exists but is not a git checkout managed by this script.
Adopt it with: awg-suite install --adopt-dashboard-from ${DASHBOARD_DIR}
(or move the directory away and re-run)."
    fi
    log "Cloning ${REPO_DASHBOARD} (tag ${tag}) into ${DASHBOARD_DIR}..."
    mkdir -p "$(dirname "$DASHBOARD_DIR")"
    git clone -q --depth 1 --branch "$tag" "$REPO_DASHBOARD" "$DASHBOARD_DIR"
    cloned_now=1
  fi

  # v1.0.4: restore data staged by --adopt-dashboard-from (db / ini / logs).
  # v1.0.7: runs BEFORE the version checks below, so adoption data always
  # lands even when the checkout is dirty or already on the right tag (the
  # early returns used to skip the restore entirely).
  restore_adopted_dashboard_data

  if [ "$cloned_now" -eq 0 ]; then
    # v1.0.7: runtime settings files are excluded from the dirty check -
    # src/certbot.ini is TRACKED upstream and is legitimately overwritten by
    # adoption and by the dashboard itself (WGDashboard writes its settings
    # there). Without the exclusion, every adopted server (and every server
    # whose settings were changed via the UI) would refuse dashboard updates
    # forever.
    if [ -n "$(git -C "$DASHBOARD_DIR" status --porcelain --untracked-files=no -- . ':(exclude)src/certbot.ini' ':(exclude)src/wg-dashboard.ini' 2>/dev/null)" ]; then
      warn "${DASHBOARD_DIR} has local modifications - refusing to switch versions."
      warn "Commit/stash them (or remove the checkout) and re-run."
      return 0
    fi
    if [ "$OPT_FORCE" -eq 0 ] && [ "$DASHBOARD_TAG" = "$tag" ] && [ -d "$DASHBOARD_DIR/src/venv" ]; then
      ok "WGDashboard ${tag} already installed - nothing to do."
      return 0
    fi
    log "Updating existing checkout to ${tag}..."
    # v1.0.7: carry the runtime settings files across the tag switch (they
    # may be locally modified, which 'git checkout -f' would discard).
    local rtdir rt
    rtdir="$(mktemp -d)"
    for rt in certbot.ini wg-dashboard.ini; do
      if [ -e "$DASHBOARD_DIR/src/$rt" ]; then cp -a "$DASHBOARD_DIR/src/$rt" "$rtdir/"; fi
    done
    git -C "$DASHBOARD_DIR" fetch -q --depth 1 origin tag "$tag"
    git -C "$DASHBOARD_DIR" checkout -q -f "$tag"
    for rt in certbot.ini wg-dashboard.ini; do
      if [ -e "$rtdir/$rt" ]; then cp -a "$rtdir/$rt" "$DASHBOARD_DIR/src/$rt"; fi
    done
    rm -rf "$rtdir"
  fi

  # Pre-seed the dashboard ini (port / bind) only when it does not exist yet,
  # so user-made settings are never overwritten.
  local ini="${DASHBOARD_DIR}/src/wg-dashboard.ini"
  if [ ! -f "$ini" ]; then
    log "Seeding ${ini} (bind ${OPT_DASH_BIND}:${OPT_DASH_PORT})..."
    cat > "$ini" <<EOF
[Server]
app_ip = ${OPT_DASH_BIND}
app_port = ${OPT_DASH_PORT}
EOF
    chmod 600 "$ini"
  else
    log "Keeping existing ${ini} (port/bind unchanged)."
  fi

  log "Running WGDashboard's own installer (creates venv, installs python deps)..."
  if ! (cd "$DASHBOARD_DIR/src" && PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/go/bin" ./wgd.sh install); then
    die "WGDashboard's installer failed. See ${DASHBOARD_DIR}/src/log/install.txt"
  fi

  # wgd.sh relaxes permissions on /etc/wireguard (world-readable keys);
  # our service runs as root, so restore the safe mode.
  chmod 700 /etc/wireguard 2>/dev/null || true

  DASHBOARD_TAG="$tag"
  save_state

  ok "WGDashboard ${tag} installed in ${DASHBOARD_DIR}."
  if [ "${ADOPTED_DASH_RESTORED:-0}" -eq 1 ] || [ -f "${STATE_DIR}/dashboard-adopted" ]; then
    ok "Web UI: http://${PRIMARY_IP}:${OPT_DASH_PORT}  (database restored - use your ORIGINAL login)"
  else
    ok "Web UI: http://${PRIMARY_IP}:${OPT_DASH_PORT}  (default login: admin / admin - change it!)"
  fi
}

install_dashboard_service() {
  hdr "WGDashboard systemd service"
  if ! have_systemd; then
    warn "systemd not running - skipping service installation."
    warn "Start the dashboard manually with: cd ${DASHBOARD_DIR}/src && ./wgd.sh start"
    return 0
  fi
  cat > /etc/systemd/system/wgdashboard.service <<EOF
[Unit]
Description=WireGuard Dashboard (WGDashboard)
After=syslog.target network-online.target
Wants=network-online.target
ConditionPathIsDirectory=/etc/wireguard

[Service]
Type=forking
PIDFile=${DASHBOARD_DIR}/src/gunicorn.pid
WorkingDirectory=${DASHBOARD_DIR}/src
ExecStart=${DASHBOARD_DIR}/src/wgd.sh start
ExecStop=${DASHBOARD_DIR}/src/wgd.sh stop
ExecReload=${DASHBOARD_DIR}/src/wgd.sh restart
TimeoutSec=120
PrivateTmp=yes
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  if ! systemctl enable wgdashboard.service >/dev/null 2>&1; then
    warn "Could not enable wgdashboard.service - check 'systemctl status wgdashboard'."
    return 0
  fi
  systemctl start wgdashboard.service >/dev/null 2>&1 || true
  sleep 3
  if systemctl is-active --quiet wgdashboard.service; then
    ok "Installed, enabled and started wgdashboard.service."
  else
    systemctl start wgdashboard.service >/dev/null 2>&1 || true
    sleep 5
    if systemctl is-active --quiet wgdashboard.service; then
      ok "Installed, enabled and started wgdashboard.service."
    else
      warn "wgdashboard.service is not running - recent journal output follows:"
      journalctl -u wgdashboard.service -n 15 --no-pager 2>/dev/null | sed 's/^/    /' || true
      warn "Inspect with: journalctl -u wgdashboard.service -n 50 --no-pager"
      local holder
      holder=$(ss -tlnp 2>/dev/null | awk -v p=":${OPT_DASH_PORT}\$" '$4 ~ p' | head -2 || true)
      if [ -n "$holder" ]; then
        warn "Port ${OPT_DASH_PORT} is currently held by:"
        printf '%s\n' "$holder" | sed 's/^/    /'
        warn "If that is an old WGDashboard, re-run 'awg-suite install' - adoption"
        warn "retires it automatically and frees the port."
      fi
    fi
  fi
}

# ------------------------------------------------------------------ v1.0.5 guards
# Starter-collision and interface-takeover helpers for seed_tunnels() and
# enable_tunnel_services(): pre-existing tunnels are left untouched unless a
# suite-created starter config actively collides with them.

subnet24_in_use() { # $1 = CIDR (e.g. 10.10.0.1/24)   $2 = interface to ignore
  local net prefix base a
  net="${1%/*}"; prefix="${1#*/}"
  [ "$prefix" = "24" ] || return 1
  base="${net%.*}"    # first three octets, e.g. 10.10.0
  for a in $(ip -4 -o addr show 2>/dev/null | awk -v ign="$2" '$2 != ign {print $4}'); do
    case "$a" in "${base}".*) return 0 ;; esac
  done
  return 1
}

is_pristine_starter() { # $1 = conf path: created by us and has no peers yet
  [ -f "$1" ] || return 1
  grep -q 'created by awg-suite-installer' "$1" 2>/dev/null || return 1
  if grep -qE '^[[:space:]]*\[Peer\]' "$1" 2>/dev/null; then return 1; fi
  return 0
}

foreign_confs_in_dir() { # $1 = dir   $2 = basename to skip (the starter)
  local f
  [ -d "$1" ] || return 0
  for f in "$1"/*.conf; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "$2" ] && continue
    basename "$f"
  done
  return 0
}

port_in_use() { # $1 = UDP port - bound by any socket (kernel wg or userspace daemon)?
  [ -n "${1:-}" ] || return 1
  command -v ss >/dev/null 2>&1 || return 1
  [ -n "$(ss -H -uln "sport = :$1" 2>/dev/null)" ]
}

retire_colliding_starter() { # $1 = conf   $2 = systemd unit   $3 = subnet CIDR   $4 = listen port
  # An unused (peer-less) starter config whose subnet or UDP port is already
  # occupied by an existing tunnel can never come up - retire it (backup +
  # unit off).
  [ -f "$1" ] || return 1
  local ifc; ifc="$(basename "$1" .conf)"
  # If the interface exists at all (running, or waiting to be taken over by
  # enable_tunnel_services), the starter is not dead weight - leave it alone.
  ip link show "$ifc" >/dev/null 2>&1 && return 1
  is_pristine_starter "$1" || return 1
  local why=""
  if subnet24_in_use "$3" "$ifc"; then
    why="subnet ${3} already serves an existing tunnel"
  elif port_in_use "${4:-}"; then
    why="UDP port ${4} is already bound by an existing tunnel"
  else
    return 1
  fi
  if ! move_to_backup "$1" "starter-$(basename "$1")"; then
    warn "Could not back up ${1} - leaving it in place."
    return 1
  fi
  sysdo stop "$2" 2>/dev/null || true
  sysdo disable "$2" 2>/dev/null || true
  sysdo reset-failed "$2" 2>/dev/null || true
  ok "Retired unused starter ${1}: ${why}"
  ok "(the starter had no peers; backup: ${ADOPT_BACKUP}/starter-$(basename "$1"))."
  return 0
}

takeover_foreign_interface() { # $1 = iface   $2 = wg-quick|awg-quick   $3 = unit
  # The interface is already up but systemd does not own it (typical for
  # pre-existing installs) - restart it under the suite's unit so it becomes
  # managed, monitored and boot-persistent. Brief blip, same config file.
  ip link show "$1" >/dev/null 2>&1 || return 0
  systemctl is-active --quiet "$3" && return 0
  warn "$1 is already up but not via ${3} - restarting it under systemd (brief blip)."
  if ! "$2" down "$1" >/dev/null 2>&1 || ip link show "$1" >/dev/null 2>&1; then
    warn "Could not hand ${1} over cleanly - leaving it running unmanaged for now."
    return 1
  fi
  ok "Stopped unmanaged ${1}; it restarts under ${3} next."
  return 0
}
# ------------------------------------------------------------------ end v1.0.5 guards

# ------------------------------------------------------------------ starter tunnels
detect_wan_if() {
  ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# v1.0.1 shipped seed configs with "Address" commented out. If a file is still
# our untouched seed (marker present, no active Address, no [Peer] section),
# make it functional: set the Address and add NAT hooks when WAN is known.
upgrade_seed_config() { # $1=file  $2=address  $3=wan_if (optional)
  local file="$1" address="$2" wan="$3"
  [ -f "$file" ] || return 0
  grep -q 'created by awg-suite-installer' "$file" 2>/dev/null || return 0
  grep -q '^\[Peer\]' "$file" 2>/dev/null && return 0

  # v1.0.3 - repair overlapping AWG 3.x header ranges. amneziawg-go >= 3.x
  # requires H1-H4 to be non-overlapping decimal ranges; seeds written by
  # installer v1.0.0 - v1.0.2 used the same value four times, which the
  # daemon rejects with EINVAL so awg-quick@awg0 never started.
  local h1 h2 h3 h4
  h1=$(sed -n 's/^H1 = \([0-9][0-9-]*\)$/\1/p' "$file")
  h2=$(sed -n 's/^H2 = \([0-9][0-9-]*\)$/\1/p' "$file")
  h3=$(sed -n 's/^H3 = \([0-9][0-9-]*\)$/\1/p' "$file")
  h4=$(sed -n 's/^H4 = \([0-9][0-9-]*\)$/\1/p' "$file")
  if [ -n "$h1" ] && [ "$h1" = "$h2" ] && [ "$h1" = "$h3" ] && [ "$h1" = "$h4" ]; then
    sed -i -e 's|^H1 = .*$|H1 = 101-200|' \
           -e 's|^H2 = .*$|H2 = 211-300|' \
           -e 's|^H3 = .*$|H3 = 311-400|' \
           -e 's|^H4 = .*$|H4 = 411-500|' "$file"
    ok "Upgraded seed ${file}: replaced identical H1-H4 (${h1}) with non-overlapping AWG3 header ranges."
  fi

  grep -q '^Address' "$file" 2>/dev/null && return 0
  sed -i "s|^# Address = .*$|Address = ${address}|" "$file" 2>/dev/null || true
  if [ -n "$wan" ] && ! grep -q '^PostUp' "$file"; then
    printf 'PostUp = iptables -A FORWARD -i %%i -j ACCEPT; iptables -t nat -A POSTROUTING -o %s -j MASQUERADE\nPostDown = iptables -D FORWARD -i %%i -j ACCEPT; iptables -t nat -D POSTROUTING -o %s -j MASQUERADE\n' "$wan" "$wan" >> "$file"
  fi
  ok "Upgraded seed ${file}: set ${address}${wan:+ + NAT via ${wan}}."
}

seed_tunnels() {
  hdr "Creating starter tunnel configs"

  if [ "$OPT_SEED" -eq 0 ]; then
    log "Skipping (per --no-seed)."
    return 0
  fi

  umask 077

  # v1.0.5: retire unused starter configs whose subnet (v1.0.6: or UDP listen
  # port) is occupied by an existing (foreign) tunnel; remember it so they are
  # not re-seeded.
  local wg_starter_retired=0 awg_starter_retired=0
  retire_colliding_starter /etc/wireguard/wg0.conf wg-quick@wg0.service 10.10.0.1/24 "$OPT_WG_PORT" && wg_starter_retired=1 || true
  retire_colliding_starter /etc/amnezia/amneziawg/awg0.conf awg-quick@awg0.service 10.11.0.1/24 "$OPT_AWG_PORT" && awg_starter_retired=1 || true

  local wan_if nat_up nat_down
  wan_if=$(detect_wan_if)
  if [ -n "$wan_if" ]; then
    nat_up="PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${wan_if} -j MASQUERADE"
    nat_down="PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${wan_if} -j MASQUERADE"
  else
    warn "Could not detect the WAN interface - seeding without NAT rules."
    warn "Add PostUp/PostDown MASQUERADE rules if peers need internet access."
  fi

  if [ ! -f /etc/wireguard/wg0.conf ]; then
    if [ "$wg_starter_retired" -eq 1 ]; then
      log "Not re-seeding wg0 - its subnet or listen port is already used by an existing tunnel."
    elif [ -n "$(foreign_confs_in_dir /etc/wireguard wg0.conf)" ] && [ "$OPT_FORCE" -eq 0 ]; then
      log "Existing tunnel configs found in /etc/wireguard - not seeding a starter wg0"
      log "(this server already runs its own tunnels; --force seeds one anyway)."
    else
    local wg_priv
    wg_priv=$(wg genkey)
    cat > /etc/wireguard/wg0.conf <<EOF
# WireGuard server tunnel (created by awg-suite-installer)
# Manage peers with WGDashboard (http://${PRIMARY_IP}:${OPT_DASH_PORT})
# or 'wg set' / 'awg-suite status'.
[Interface]
PrivateKey = ${wg_priv}
ListenPort = ${OPT_WG_PORT}
Address = 10.10.0.1/24
${nat_up}
${nat_down}
EOF
    chmod 600 /etc/wireguard/wg0.conf
    SEEDED_WG=1
    ok "Created /etc/wireguard/wg0.conf (UDP ${OPT_WG_PORT}, 10.10.0.1/24, fresh keypair)."
    fi
  else
    upgrade_seed_config /etc/wireguard/wg0.conf 10.10.0.1/24 "$wan_if"
    ok "/etc/wireguard/wg0.conf already exists - left untouched (unless upgraded above)."
  fi

  if [ ! -f /etc/amnezia/amneziawg/awg0.conf ]; then
    if [ "$awg_starter_retired" -eq 1 ]; then
      log "Not re-seeding awg0 - its subnet or listen port is already used by an existing tunnel."
    elif [ -n "$(foreign_confs_in_dir /etc/amnezia/amneziawg awg0.conf)" ] && [ "$OPT_FORCE" -eq 0 ]; then
      log "Existing tunnel configs found in /etc/amnezia/amneziawg - not seeding a starter awg0"
      log "(this server already runs its own tunnels; --force seeds one anyway)."
    else
    local awg_priv
    awg_priv=$(wg genkey)
    cat > /etc/amnezia/amneziawg/awg0.conf <<EOF
# AmneziaWG server tunnel (created by awg-suite-installer)
# AWG 3.x obfuscation params: Jc/Jmin/Jmax junk packets, S1/S2 handshake
# padding, H1-H4 message-type ranges (must be non-overlapping, and every
# peer that connects here must use the same H1-H4/S1/S2 values).
[Interface]
PrivateKey = ${awg_priv}
ListenPort = ${OPT_AWG_PORT}
Jc = 4
Jmin = 40
Jmax = 70
S1 = 76
S2 = 86
H1 = 101-200
H2 = 211-300
H3 = 311-400
H4 = 411-500
Address = 10.11.0.1/24
${nat_up}
${nat_down}
EOF
    chmod 600 /etc/amnezia/amneziawg/awg0.conf
    SEEDED_AWG=1
    ok "Created /etc/amnezia/amneziawg/awg0.conf (UDP ${OPT_AWG_PORT}, 10.11.0.1/24, fresh keypair + obfuscation params)."
    fi
  else
    upgrade_seed_config /etc/amnezia/amneziawg/awg0.conf 10.11.0.1/24 "$wan_if"
    ok "/etc/amnezia/amneziawg/awg0.conf already exists - left untouched (unless upgraded above)."
  fi

  save_state
}

enable_tunnel_services() {
  hdr "Enabling tunnel services"
  if ! have_systemd; then
    warn "systemd not running - tunnels will not be started here."
    return 0
  fi
  local units=()
  if [ -f /etc/wireguard/wg0.conf ]; then
    if systemctl enable wg-quick@wg0.service >/dev/null 2>&1; then
      units+=("wg-quick@wg0")
    else
      warn "Could not enable wg-quick@wg0.service (missing wg-quick@.service?)."
    fi
  fi
  if [ -f /etc/amnezia/amneziawg/awg0.conf ]; then
    if systemctl enable awg-quick@awg0.service >/dev/null 2>&1; then
      units+=("awg-quick@awg0")
    else
      warn "Could not enable awg-quick@awg0.service (missing awg-quick@.service?)."
    fi
  fi
  # v1.0.5: AWG configs adopted from /etc/wireguard earlier in this run must
  # end up enabled + running even on a fresh install where awg-quick@.service
  # did not exist yet at adoption time.
  local adopted
  for adopted in ${ADOPTED_AWG_UNITS:-}; do
    systemctl is-active --quiet "awg-quick@${adopted}.service" && continue
    if systemctl enable "awg-quick@${adopted}.service" >/dev/null 2>&1; then
      units+=("awg-quick@${adopted}")
    else
      warn "Could not enable awg-quick@${adopted}.service (missing awg-quick@.service?)."
    fi
  done
  [ "${#units[@]}" -gt 0 ] || return 0
  if [ ! -e /dev/net/tun ]; then
    warn "/dev/net/tun missing - tunnels are enabled and start on the next boot."
    ok "Enabled: ${units[*]}"
    return 0
  fi
  local u ifc tool failed=0
  for u in "${units[@]}"; do
    # v1.0.5: if the tunnel is already up but systemd does not own it (a
    # pre-existing install started it), hand it over with a brief restart.
    ifc="${u#*@}"
    case "$u" in wg-quick@*) tool="wg-quick" ;; *) tool="awg-quick" ;; esac
    if ! takeover_foreign_interface "$ifc" "$tool" "${u}.service" \
       && ip link show "$ifc" >/dev/null 2>&1; then
      warn "Leaving ${u} for the next boot (${ifc} runs from an unmanaged source)."
      continue
    fi
    systemctl reset-failed "${u}.service" >/dev/null 2>&1 || true
    if ! systemctl start "${u}.service" >/dev/null 2>&1; then
      sleep 2
      systemctl start "${u}.service" >/dev/null 2>&1 || true
    fi
    if systemctl is-active --quiet "${u}.service"; then
      ok "Started ${u}."
    else
      failed=1
      warn "${u} did NOT start - recent journal output follows:"
      local jl
      jl="$(journalctl -u "${u}.service" -n 12 --no-pager 2>/dev/null || true)"
      printf '%s\n' "$jl" | sed 's/^/    /'
      warn "Inspect with: journalctl -u ${u}.service -n 50 --no-pager"
      if printf '%s\n' "$jl" | grep -qE 'Address already in use|File exists'; then
        # v1.0.6: name the actual holder (subnet and/or UDP listen port)
        local conf addr lport base a proc p sholders="" pholders=""
        case "$u" in wg-quick@*) conf="/etc/wireguard/${ifc}.conf" ;; *) conf="/etc/amnezia/amneziawg/${ifc}.conf" ;; esac
        addr=$(sed -n 's/^Address[[:space:]]*=[[:space:]]*//p' "$conf" 2>/dev/null | awk 'NR==1')
        lport=$(sed -n 's/^ListenPort[[:space:]]*=[[:space:]]*//p' "$conf" 2>/dev/null | awk 'NR==1')
        base="${addr%/*}"; base="${base%.*}"
        if [ -n "$addr" ]; then
          for a in $(ip -4 -o addr show 2>/dev/null | awk -v ign="$ifc" '$2 != ign {print $2"="$4}'); do
            case "${a#*=}" in "${base}".*) sholders="${sholders} ${a%%=*}(${a#*=})" ;; esac
          done
        fi
        if [ -n "$lport" ] && command -v ss >/dev/null 2>&1; then
          while IFS= read -r p; do
            [ -n "$p" ] || continue
            proc=$(printf '%s\n' "$p" | sed -n 's/.*users(("\([^"]*\)".*/\1/p')
            if [ -n "$proc" ]; then pholders="${pholders} ${proc}"; else pholders="${pholders} kernel-tunnel-socket"; fi
          done < <(ss -H -uln "sport = :${lport}" 2>/dev/null)
        fi
        [ -n "$sholders" ] && warn "Hint: subnet ${base}.0/24 is already used by:${sholders}."
        [ -n "$pholders" ] && warn "Hint: UDP port ${lport} is already bound by:${pholders}."
        if [ -z "${sholders}${pholders}" ]; then
          warn "Hint: another tunnel already uses this subnet or listen port."
        fi
        warn "Edit 'Address ='/'ListenPort =' in ${conf}, or remove the file if the tunnel is unused."
      fi
      case "$u" in
        awg-quick@*)
          if printf '%s\n' "$jl" | grep -q 'Invalid argument'; then
            warn "Hint: 'Invalid argument' from awg setconf usually means bad AWG obfuscation"
            warn "params. In AWG 3.x, H1-H4 must be NON-OVERLAPPING decimal ranges"
            warn "(e.g. H1 = 101-200, H2 = 211-300, ...) matching on server and peers."
          fi
          ;;
      esac
    fi
  done
  [ "$failed" -eq 0 ] && ok "All tunnel services active: ${units[*]}"
  return 0
}

# ------------------------------------------------------------------ sysctl / firewall
configure_sysctl() {
  hdr "Kernel forwarding (sysctl)"
  cat > "$SYSCTL_FILE" <<EOF
# Managed by awg-suite-installer.sh - forwarding for WG/AWG tunnels
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
  if sysctl --load="$SYSCTL_FILE" >/dev/null 2>&1; then
    ok "Applied ${SYSCTL_FILE} - IPv4 + IPv6 forwarding active now."
  else
    warn "sysctl could not apply ${SYSCTL_FILE} immediately (conflicting settings"
    warn "or container restriction). It will activate on the next boot."
  fi
}

configure_firewall() {
  hdr "Firewall (ufw)"
  if ! command -v ufw >/dev/null 2>&1; then
    log "ufw not installed - nothing to do."
    return 0
  fi
  if ! ufw status 2>/dev/null | grep -q "Status: active"; then
    log "ufw is not active - no rules added."
    return 0
  fi
  ufw allow "${OPT_WG_PORT}"/udp comment 'awg-suite WireGuard' >/dev/null 2>&1 || warn "ufw: could not add ${OPT_WG_PORT}/udp"
  ufw allow "${OPT_AWG_PORT}"/udp comment 'awg-suite AmneziaWG' >/dev/null 2>&1 || warn "ufw: could not add ${OPT_AWG_PORT}/udp"
  ufw allow "${OPT_DASH_PORT}"/tcp comment 'awg-suite WGDashboard' >/dev/null 2>&1 || warn "ufw: could not add ${OPT_DASH_PORT}/tcp"
  ok "ufw rules added: ${OPT_WG_PORT}/udp, ${OPT_AWG_PORT}/udp, ${OPT_DASH_PORT}/tcp."
}

# ------------------------------------------------------------------ auto-update timer
install_update_timer() {
  hdr "Automatic update timer (systemd)"
  if [ "$OPT_AUTO_UPDATE" -eq 0 ]; then
    log "Skipping (per --no-auto-update)."
    return 0
  fi
  if ! have_systemd; then
    warn "systemd not running - auto-update timer not installed."
    return 0
  fi
  cat > /etc/systemd/system/awg-suite-update.service <<EOF
[Unit]
Description=AWG Suite (WireGuard + AmneziaWG + WGDashboard) updater
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_INSTALL_PATH} update --auto
TimeoutStartSec=3600
Nice=10
EOF
  cat > /etc/systemd/system/awg-suite-update.timer <<EOF
[Unit]
Description=Weekly AWG Suite update check

[Timer]
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=45m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  if systemctl enable --now awg-suite-update.timer >/dev/null 2>&1; then
    ok "awg-suite-update.timer enabled (Sundays ~04:00, randomized +/- 45min)."
  else
    warn "Could not enable awg-suite-update.timer - auto-update inactive."
  fi
}

# ------------------------------------------------------------------ self update
self_update() {
  [ "$OPT_SELF_UPDATE" -eq 1 ] || return 0
  [ -f "$SCRIPT_INSTALL_PATH" ] || return 0
  local tmp="${TMPDIR_AWG}/self-update.sh"
  log "Checking for installer updates (${SELF_UPDATE_URL})..."
  if ! curl -fsSL --retry 2 --connect-timeout 15 -o "$tmp" "$SELF_UPDATE_URL"; then
    warn "Could not fetch script update - keeping the current version."
    return 0
  fi
  if ! bash -n "$tmp" 2>/dev/null || ! grep -q '^AWG_SUITE_INSTALLER=1' "$tmp"; then
    warn "Downloaded script failed validation - keeping the current version."
    return 0
  fi
  if cmp -s "$tmp" "$SCRIPT_INSTALL_PATH"; then
    ok "Installer script is up to date."
    return 0
  fi
  install -m 0755 "$tmp" "$SCRIPT_INSTALL_PATH"
  ok "Installer script updated to the latest version from the repo."
}

install_self() {
  local src
  if src=$(script_source_file); then
    if [ "$src" != "$SCRIPT_INSTALL_PATH" ]; then
      install -m 0755 "$src" "$SCRIPT_INSTALL_PATH"
      ok "Installed script as ${SCRIPT_INSTALL_PATH} (shortcut: awg-suite)."
    fi
    ln -sf "$SCRIPT_INSTALL_PATH" "$SCRIPT_SYMLINK"
  else
    # Running from a pipe (curl | sudo bash): fetch the canonical copy from
    # the repo so the installed script has a real file on disk.
    local tmp="${TMPDIR_AWG}/installer-from-repo.sh"
    log "Running from stdin - fetching installer from ${SELF_UPDATE_URL}..."
    if ! curl -fsSL --retry 2 --connect-timeout 15 -o "$tmp" "$SELF_UPDATE_URL" \
      || ! bash -n "$tmp" 2>/dev/null \
      || ! grep -q '^AWG_SUITE_INSTALLER=1' "$tmp"; then
      die "Could not fetch a valid installer from ${SELF_UPDATE_URL}.
Download it manually and re-run:
    curl -fsSL ${SELF_UPDATE_URL} -o awg-suite-installer.sh
    sudo ./awg-suite-installer.sh install"
    fi
    install -m 0755 "$tmp" "$SCRIPT_INSTALL_PATH"
    ln -sf "$SCRIPT_INSTALL_PATH" "$SCRIPT_SYMLINK"
    ok "Installed script as ${SCRIPT_INSTALL_PATH} (shortcut: awg-suite)."
  fi
}

# ------------------------------------------------------------------ commands
print_banner() {
  printf '\n'
  printf '%s\n' "${C_HDR}=========================================================================${C_RST}"
  printf '%s\n' "${C_HDR}  AWG Suite - WireGuard + AmneziaWG + WGDashboard${C_RST}"
  printf '%s\n' "${C_HDR}=========================================================================${C_RST}"
  printf '  WireGuard    : UDP %-6s  (config: /etc/wireguard)\n' "$OPT_WG_PORT"
  printf '  AmneziaWG    : UDP %-6s  (config: /etc/amnezia/amneziawg)\n' "$OPT_AWG_PORT"
  if [ "$OPT_DASHBOARD" -eq 1 ] && [ "$DASHBOARD_TAG" != "" ]; then
    printf '  WGDashboard  : http://%s:%s  (%s)\n' "$PRIMARY_IP" "$OPT_DASH_PORT" "$DASHBOARD_TAG"
  fi
  printf '  Auto-update  : %s\n' "$([ "$OPT_AUTO_UPDATE" -eq 1 ] && have_systemd && echo 'weekly systemd timer' || echo 'manual (awg-suite update)')"
  printf '%s\n' "-------------------------------------------------------------------------"
  local tunits=""
  if [ -f /etc/wireguard/wg0.conf ]; then tunits="wg-quick@wg0"; fi
  if [ -f /etc/amnezia/amneziawg/awg0.conf ]; then tunits="${tunits:+${tunits} }awg-quick@awg0"; fi
  if [ -z "$tunits" ]; then tunits="'wg-quick@*' 'awg-quick@*'"; fi
  printf '  Next steps:\n'
  if [ "${ADOPTED_DASH_RESTORED:-0}" -eq 1 ] || [ -f "${STATE_DIR}/dashboard-adopted" ]; then
    printf '    * Open the dashboard and log in with your ORIGINAL credentials (adopted).\n'
  else
    printf '    * Open the dashboard, log in (admin/admin) and SET A NEW PASSWORD.\n'
  fi
  printf '    * Add peers/tunnels from the dashboard, or edit the seeded configs.\n'
  printf '    * Tunnel services:  systemctl status %s\n' "$tunits"
  printf '    * Suite management: awg-suite status | update | uninstall\n'
  printf '%s\n' "-------------------------------------------------------------------------"
  printf '  Component versions: amneziawg-go %s | amneziawg-tools %s | dashboard %s\n' \
    "${AWG_GO_TAG:-n/a}" "${AWG_TOOLS_TAG:-n/a}" "${DASHBOARD_TAG:-n/a}"
  printf '%s\n' "${C_HDR}=========================================================================${C_RST}"
}

cmd_install() {
  load_state
  # re-apply explicit CLI flags over state values
  [ -n "${USER_DASH_PORT:-}" ]  && OPT_DASH_PORT="$USER_DASH_PORT"
  [ -n "${USER_DASH_BIND:-}" ]  && OPT_DASH_BIND="$USER_DASH_BIND"
  [ -n "${USER_WG_PORT:-}" ]    && OPT_WG_PORT="$USER_WG_PORT"
  [ -n "${USER_AWG_PORT:-}" ]   && OPT_AWG_PORT="$USER_AWG_PORT"

  if [ -f "$STATE_DIR/state.env" ]; then
    log "Existing installation detected - this run will repair/upgrade in place."
  fi

  run_adoption

  hdr "Installing dependencies (apt)"
  apt_update_retry
  ensure_packages "${BASE_PACKAGES[@]}"

  install_self
  install_wireguard
  install_awg_go "${OPT_AWG_GO_TAG:-$(latest_awg_go_tag)}"
  install_awg_tools "${OPT_AWG_TOOLS_TAG:-$(latest_awg_tools_tag)}"
  if [ "$OPT_DASHBOARD" -eq 1 ]; then
    install_dashboard "$(dashboard_target_tag)"
    install_dashboard_service
  else
    log "Skipping WGDashboard (per --no-dashboard)."
  fi

  seed_tunnels
  enable_tunnel_services
  configure_sysctl
  configure_firewall
  install_update_timer

  INSTALL_DATE="$(date -Is)"
  save_state
  print_banner
  ok "Install complete. Log: ${LOG_FILE}"
}

cmd_update() {
  require_installed
  load_state

  hdr "Updating AWG suite"
  log "Installed: amneziawg-go ${AWG_GO_TAG} | amneziawg-tools ${AWG_TOOLS_TAG} | dashboard ${DASHBOARD_TAG}"

  local changed_wg=0 changed_awg_go=0 changed_awg_tools=0 changed_dash=0

  make_tmpdir
  self_update

  hdr "Updating apt packages (WireGuard tools + suite dependencies)"
  apt_update_retry
  local wg_ver_before=""
  wg_ver_before=$(wg --version 2>/dev/null || true)
  if apt_get install --only-upgrade wireguard-tools >/dev/null 2>&1; then
    if [ "$(wg --version 2>/dev/null || true)" != "$wg_ver_before" ]; then
      changed_wg=1
      ok "wireguard-tools upgraded: ${wg_ver_before} -> $(wg --version 2>/dev/null || echo '?')"
    else
      ok "wireguard-tools is at the latest distro version."
    fi
  fi

  local tag
  tag="${OPT_AWG_GO_TAG:-$(latest_awg_go_tag)}"
  if [ "$tag" != "$AWG_GO_TAG" ] || [ "$OPT_FORCE" -eq 1 ]; then
    log "amneziawg-go: ${AWG_GO_TAG:-none} -> ${tag}"
    install_awg_go "$tag"
    changed_awg_go=1
  else
    ok "amneziawg-go ${AWG_GO_TAG} is up to date."
  fi

  tag="${OPT_AWG_TOOLS_TAG:-$(latest_awg_tools_tag)}"
  if [ "$tag" != "$AWG_TOOLS_TAG" ] || [ "$OPT_FORCE" -eq 1 ]; then
    log "amneziawg-tools: ${AWG_TOOLS_TAG:-none} -> ${tag}"
    install_awg_tools "$tag"
    changed_awg_tools=1
  else
    ok "amneziawg-tools ${AWG_TOOLS_TAG} is up to date."
  fi

  if [ "$OPT_DASHBOARD" -eq 1 ] && [ -d "$DASHBOARD_DIR/.git" ]; then
    tag="$(dashboard_target_tag)"
    if [ "$tag" != "$DASHBOARD_TAG" ] || [ "$OPT_FORCE" -eq 1 ]; then
      if [ -n "$(git -C "$DASHBOARD_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        warn "${DASHBOARD_DIR} has local modifications - dashboard update skipped."
      else
        log "WGDashboard: ${DASHBOARD_TAG} -> ${tag}"
        sysdo stop wgdashboard.service || true
        install_dashboard "$tag"
        changed_dash=1
      fi
    else
      ok "WGDashboard ${DASHBOARD_TAG} is up to date."
    fi
  fi

  # ---- restart affected running services ----
  if have_systemd; then
    hdr "Restarting affected services"
    if [ "$changed_awg_go" -eq 1 ] || [ "$changed_awg_tools" -eq 1 ]; then
      local awg_units
      awg_units=$(systemctl list-units --type=service --state=running --plain --no-legend 'awg-quick@*' 2>/dev/null | awk '{print $1}')
      if [ -n "$awg_units" ]; then
        # shellcheck disable=SC2086
        systemctl restart $awg_units 2>/dev/null \
          && ok "Restarted: ${awg_units//$'\n'/ }" \
          || warn "Failed to restart some awg-quick tunnels - check manually."
      fi
    fi
    if [ "$changed_wg" -eq 1 ]; then
      local wg_units
      wg_units=$(systemctl list-units --type=service --state=running --plain --no-legend 'wg-quick@*' 2>/dev/null | awk '{print $1}')
      if [ -n "$wg_units" ]; then
        # shellcheck disable=SC2086
        systemctl restart $wg_units 2>/dev/null \
          && ok "Restarted: ${wg_units//$'\n'/ }" \
          || warn "Failed to restart some wg-quick tunnels - check manually."
      fi
    fi
    if [ "$changed_dash" -eq 1 ]; then
      systemctl restart wgdashboard.service 2>/dev/null \
        && ok "Restarted wgdashboard.service" \
        || warn "Failed to restart wgdashboard.service - check manually."
    else
      systemctl try-restart wgdashboard.service >/dev/null 2>&1 || true
    fi
  else
    log "systemd not running - service restarts skipped."
  fi

  save_state
  ok "Update check complete."
  log "Components: amneziawg-go ${AWG_GO_TAG} | amneziawg-tools ${AWG_TOOLS_TAG} | dashboard ${DASHBOARD_TAG}"
}

cmd_uninstall() {
  load_state
  [ -f "$STATE_DIR/state.env" ] || warn "No state file found - removing everything this script manages anyway."

  hdr "Stopping services"
  if have_systemd; then
    systemctl stop awg-suite-update.timer 2>/dev/null || true
    systemctl stop wgdashboard.service 2>/dev/null || true
    systemctl stop 'awg-quick@*' 2>/dev/null || true
    systemctl stop 'wg-quick@*' 2>/dev/null || true
    systemctl disable wgdashboard.service 'awg-quick@*' 'wg-quick@*' \
      awg-suite-update.timer awg-suite-update.service >/dev/null 2>&1 || true
  else
    if [ -f "${DASHBOARD_DIR}/src/gunicorn.pid" ]; then
      (cd "${DASHBOARD_DIR}/src" && ./wgd.sh stop) >/dev/null 2>&1 || true
    fi
  fi

  if [ "$OPT_PURGE" -eq 1 ]; then
    if [ "$OPT_YES" -ne 1 ]; then
      echo
      warn "--purge will PERMANENTLY DELETE:"
      warn "  * /etc/wireguard        (WireGuard tunnel configs + private keys)"
      warn "  * /etc/amnezia           (AmneziaWG tunnel configs + private keys)"
      warn "  * dashboard data backup will still be kept in ${BACKUP_DIR}"
      printf '%s' "Type 'purge' to confirm: "
      local reply=""
      read -r reply || true
      [ "$reply" = "purge" ] || die "Aborted - nothing was deleted."
    fi
  fi

  hdr "Backing up dashboard data"
  if [ -d "$DASHBOARD_DIR/src" ]; then
    mkdir -p "$BACKUP_DIR"
    local bk
    bk="${BACKUP_DIR}/wgdashboard-$(date +%Y%m%d-%H%M%S).tar.gz"
    if tar czf "$bk" -C "$DASHBOARD_DIR/src" db wg-dashboard.ini ssl-tls.ini 2>/dev/null; then
      ok "Dashboard database + settings saved to ${bk}"
    else
      warn "Dashboard backup incomplete (no database yet?)."
    fi
  fi

  hdr "Removing files"
  rm -f /usr/bin/amneziawg-go \
        /usr/bin/awg /usr/bin/awg-quick \
        /usr/share/man/man8/awg.8 /usr/share/man/man8/awg-quick.8 \
        /usr/share/bash-completion/completions/awg \
        /usr/share/bash-completion/completions/awg-quick \
        /usr/lib/systemd/system/awg-quick@.service \
        /usr/lib/systemd/system/awg-quick.target \
        /etc/systemd/system/wgdashboard.service \
        /etc/systemd/system/awg-suite-update.service \
        /etc/systemd/system/awg-suite-update.timer \
        "$SYSCTL_FILE"
  rm -rf "$DASHBOARD_DIR"

  if [ "${GO_INSTALLED_BY_US:-0}" -eq 1 ]; then
    rm -rf /usr/local/go
    ok "Removed /usr/local/go (toolchain installed by this script)."
  fi

  rm -rf "$STATE_DIR" "$LOG_DIR"
  rm -f "$SCRIPT_SYMLINK"

  if have_systemd; then
    systemctl daemon-reload
  fi

  if [ "$OPT_PURGE" -eq 1 ]; then
    hdr "Purging configs and packages"
    rm -rf /etc/wireguard /etc/amnezia
    ok "Removed /etc/wireguard and /etc/amnezia (all tunnel configs and keys)."
    # Remove only packages that cannot break the base system:
    local purge_pkgs=""
    local p
    for p in wireguard-tools build-essential pkg-config; do
      if dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null | grep -q '^ii'; then
        purge_pkgs="${purge_pkgs:+$purge_pkgs }$p"
      fi
    done
    if [ -n "$purge_pkgs" ]; then
      # shellcheck disable=SC2086
      apt_get purge $purge_pkgs >/dev/null && ok "Purged apt packages: ${purge_pkgs}"
    fi
    apt_get autoremove >/dev/null 2>&1 || true
    ok "Note: python3, git, curl and friends were intentionally left installed."
  else
    ok "Kept /etc/wireguard and /etc/amnezia (use --purge to delete configs and keys)."
  fi

  rm -f "$SCRIPT_INSTALL_PATH" 2>/dev/null || true
  ok "Uninstall complete. Backups (if any): ${BACKUP_DIR}"
}

cmd_status() {
  load_state
  hdr "AWG Suite status"
  log "Installer : v${SCRIPT_VERSION} (installed: ${INSTALL_DATE:-n/a})"
  log "Platform  : ${PRETTY_NAME:-$(uname -sr)} ($(uname -m))"

  printf '\nComponents:\n'
  printf '  WireGuard tools  : %s\n' "$(wg --version 2>/dev/null || echo 'NOT INSTALLED')"
  local ago_ver
  if [ -x /usr/bin/amneziawg-go ]; then
    ago_ver=$(/usr/bin/amneziawg-go --version 2>/dev/null || true)
    [ -n "$ago_ver" ] || ago_ver="installed (${AWG_GO_TAG:-unknown tag})"
  else
    ago_ver='NOT INSTALLED'
  fi
  printf '  amneziawg-go     : %s\n' "$ago_ver"
  printf '  amneziawg-tools  : %s\n' "$(awg --version 2>/dev/null || echo 'NOT INSTALLED')"
  printf '  WGDashboard      : %s at %s\n' "${DASHBOARD_TAG:-not installed}" "${DASHBOARD_DIR}"

  printf '\nPorts:\n'
  printf '  WireGuard UDP %s | AmneziaWG UDP %s | Dashboard TCP %s\n' "$OPT_WG_PORT" "$OPT_AWG_PORT" "$OPT_DASH_PORT"

  printf '\nTunnels (configs):\n'
  ls -1 /etc/wireguard/*.conf 2>/dev/null | sed 's/^/  WG  /' || printf '  (none in /etc/wireguard)\n'
  ls -1 /etc/amnezia/amneziawg/*.conf 2>/dev/null | sed 's/^/  AWG /' || printf '  (none in /etc/amnezia/amneziawg)\n'

  printf '\nStandardization scan:\n'
  adoption_report

  if have_systemd; then
    printf '\nServices:\n'
    systemctl --no-legend --plain list-units 'wg-quick@*' 'awg-quick@*' 'wgdashboard.service' 'awg-suite-update.timer' 2>/dev/null \
      | awk '{printf "  %-28s %s %s\n", $1, $3, $4}'
    local next
    next=$(systemctl list-timers --no-legend 'awg-suite-update.timer' 2>/dev/null | awk '{print $1, $2, $3}')
    [ -n "$next" ] && printf '\nNext auto-update: %s\n' "$next"
  else
    printf '\nServices: systemd not running.\n'
  fi

  if [ -f "${STATE_DIR}/dashboard-adopted" ]; then
    printf '\nDashboard URL: http://%s:%s (login: your ORIGINAL credentials - dashboard was adopted)\n' "$PRIMARY_IP" "$OPT_DASH_PORT"
  else
    printf '\nDashboard URL: http://%s:%s (login: admin/admin unless changed)\n' "$PRIMARY_IP" "$OPT_DASH_PORT"
  fi
}

usage() {
  cat <<'EOF'
awg-suite-installer.sh - WireGuard + AmneziaWG + WGDashboard in one step

Usage:
  awg-suite-installer.sh [command] [options]
  curl -fsSL <url> | sudo bash        # one-step install (command optional)

Commands:
  install      Install / repair / upgrade the full suite (default)
  update       Update all components and the script itself
  uninstall    Remove services and binaries (configs kept unless --purge)
  status       Show versions, services and the next auto-update
  help         Show this help

Options:
  --dashboard-port N     WGDashboard HTTP port            (default 10086)
  --dashboard-bind IP    WGDashboard bind address         (default 0.0.0.0)
  --wg-port N            seeded WireGuard listen port     (default 51820)
  --awg-port N           seeded AmneziaWG listen port     (default 42666)
  --no-seed              do not create starter wg0/awg0 tunnel configs
  --no-dashboard         skip WGDashboard (lifts the OS version floor)
  --no-auto-update       do not install the weekly auto-update timer
  --awg-go-tag TAG       pin amneziawg-go to an upstream tag
  --awg-tools-tag TAG    pin amneziawg-tools to an upstream tag
  --dashboard-tag TAG    pin WGDashboard to an upstream tag
  --go-version V         use a specific Go toolchain version
  --force                rebuild/reinstall even when up to date
  --auto                 non-interactive mode (systemd timer / CI)
  --no-self-update       do not refresh the installed script itself
  --purge                uninstall: also delete configs, keys, dashboard data
  --yes, -y              assume yes everywhere

Adoption options (pre-existing installs):
  Detection is automatic. When 'install' finds a live foreign install it is
  adopted right away - full backups first, data preserved. Opt out with:
  --no-adopt             scan and report, but do not adopt anything

  Explicit overrides (these disable the automatic adoption above):
  --adopt-dashboard-from DIR
                         adopt a specific WGDashboard checkout: relocate it
                         to /opt/wgdashboard under wgdashboard.service, keeping
                         its database (peers, logins, settings); the old copy
                         and units are backed up first
  --adopt-awg-configs    move AWG-style configs from /etc/wireguard to
                         /etc/amnezia/amneziawg and run them via awg-quick@
  --adopt-clean-path     remove wg/awg binaries under /usr/local that shadow
                         the suite's /usr/bin versions

  (Every move is backed up to /var/backups/awg-suite/pre-adopt-<date>/ first;
  the dashboard database and tunnel configs/keys always survive adoption.)

Examples:
  curl -fsSL https://raw.githubusercontent.com/cddeppe/awg-suite/master/awg-suite-installer.sh | sudo bash
  curl -fsSL https://raw.githubusercontent.com/cddeppe/awg-suite/master/awg-suite-installer.sh | sudo bash -s -- --dashboard-port 8080
  sudo awg-suite update
  sudo awg-suite uninstall --purge
EOF
}

# ------------------------------------------------------------------ arg parsing
parse_args() {
  if [ $# -ge 1 ]; then
    case "$1" in
      install|update|uninstall|status|help|--help|-h)
        CMD="$1"; shift ;;
      -*)
        CMD="install" ;;  # options without a command default to install
      *)
        err "Unknown command: $1"; usage; exit 1 ;;
    esac
  else
    CMD="install"  # bare invocation (curl | sudo bash) defaults to install
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --dashboard-port|--dashboard-bind|--wg-port|--awg-port|--awg-go-tag|--awg-tools-tag|--dashboard-tag|--go-version|--adopt-dashboard-from)
        [ $# -ge 2 ] || die "Option $1 requires a value."
        case "$1" in
          --dashboard-port)  OPT_DASH_PORT="$2"; USER_DASH_PORT="$2" ;;
          --dashboard-bind) OPT_DASH_BIND="$2"; USER_DASH_BIND="$2" ;;
          --wg-port)         OPT_WG_PORT="$2"; USER_WG_PORT="$2" ;;
          --awg-port)        OPT_AWG_PORT="$2"; USER_AWG_PORT="$2" ;;
          --awg-go-tag)      OPT_AWG_GO_TAG="$2" ;;
          --awg-tools-tag)   OPT_AWG_TOOLS_TAG="$2" ;;
          --dashboard-tag)   OPT_DASHBOARD_TAG="$2" ;;
          --go-version)      OPT_GO_VERSION="$2" ;;
          --adopt-dashboard-from) OPT_ADOPT_DASH_FROM="$2" ;;
        esac
        shift 2 ;;
      --no-seed)         OPT_SEED=0; shift ;;
      --no-dashboard)    OPT_DASHBOARD=0; shift ;;
      --no-adopt)        OPT_NO_ADOPT=1; shift ;;
      --no-auto-update)  OPT_AUTO_UPDATE=0; shift ;;
      --force)           OPT_FORCE=1; shift ;;
      --no-self-update)  OPT_SELF_UPDATE=0; shift ;;
      --auto)            OPT_AUTO=1; shift ;;
      --purge)           OPT_PURGE=1; shift ;;
      --yes|-y)          OPT_YES=1; shift ;;
      --adopt-awg-configs) OPT_ADOPT_AWG_CONF=1; shift ;;
      --adopt-clean-path)  OPT_ADOPT_CLEAN_PATH=1; shift ;;
      --help|-h)         usage; exit 0 ;;
      *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
  done

  # basic sanity on numeric options
  case "$OPT_DASH_PORT$OPT_WG_PORT$OPT_AWG_PORT" in
    *[!0-9]*) die "Ports must be numeric." ;;
  esac
}

main() {
  setup_colors
  local original_args=("$@")
  parse_args "$@"

  case "$CMD" in
    help|--help|-h) usage; exit 0 ;;
  esac

  require_root "${original_args[@]}"
  setup_logging
  acquire_lock
  make_tmpdir
  detect_environment

  case "$CMD" in
    install)   cmd_install ;;
    update)    cmd_update ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
  esac
}

main "$@"
