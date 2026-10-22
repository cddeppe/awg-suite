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
SCRIPT_VERSION="1.0.1"

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

  if [ ! -d "$DASHBOARD_DIR/.git" ]; then
    if [ -d "$DASHBOARD_DIR" ]; then
      die "${DASHBOARD_DIR} exists but is not a git checkout managed by this script.
Move it away (or remove it) and re-run."
    fi
    log "Cloning ${REPO_DASHBOARD} (tag ${tag}) into ${DASHBOARD_DIR}..."
    mkdir -p "$(dirname "$DASHBOARD_DIR")"
    git clone -q --depth 1 --branch "$tag" "$REPO_DASHBOARD" "$DASHBOARD_DIR"
  else
    if [ -n "$(git -C "$DASHBOARD_DIR" status --porcelain 2>/dev/null)" ]; then
      warn "${DASHBOARD_DIR} has local modifications - refusing to switch versions."
      warn "Commit/stash them (or remove the checkout) and re-run."
      return 0
    fi
    if [ "$OPT_FORCE" -eq 0 ] && [ "$DASHBOARD_TAG" = "$tag" ] && [ -d "$DASHBOARD_DIR/src/venv" ]; then
      ok "WGDashboard ${tag} already installed - nothing to do."
      return 0
    fi
    log "Updating existing checkout to ${tag}..."
    git -C "$DASHBOARD_DIR" fetch -q --depth 1 origin tag "$tag"
    git -C "$DASHBOARD_DIR" checkout -q "$tag"
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
  ok "Web UI: http://${PRIMARY_IP}:${OPT_DASH_PORT}  (default login: admin / admin - change it!)"
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
  if systemctl enable wgdashboard.service >/dev/null 2>&1; then
    ok "Installed and enabled wgdashboard.service."
  else
    warn "Could not enable wgdashboard.service - check 'systemctl status wgdashboard'."
  fi
}

# ------------------------------------------------------------------ starter tunnels
seed_tunnels() {
  hdr "Creating starter tunnel configs"

  if [ "$OPT_SEED" -eq 0 ]; then
    log "Skipping (per --no-seed)."
    return 0
  fi

  umask 077

  if [ ! -f /etc/wireguard/wg0.conf ]; then
    local wg_priv
    wg_priv=$(wg genkey)
    cat > /etc/wireguard/wg0.conf <<EOF
# WireGuard server tunnel (created by awg-suite-installer)
# Manage peers with WGDashboard (http://${PRIMARY_IP}:${OPT_DASH_PORT})
# or 'wg set' / 'awg-suite status'.
[Interface]
PrivateKey = ${wg_priv}
ListenPort = ${OPT_WG_PORT}
# Address = 10.10.0.1/24
# PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
# PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF
    chmod 600 /etc/wireguard/wg0.conf
    SEEDED_WG=1
    ok "Created /etc/wireguard/wg0.conf (UDP ${OPT_WG_PORT}, fresh keypair)."
  else
    ok "/etc/wireguard/wg0.conf already exists - left untouched."
  fi

  if [ ! -f /etc/amnezia/amneziawg/awg0.conf ]; then
    local awg_priv
    awg_priv=$(wg genkey)
    cat > /etc/amnezia/amneziawg/awg0.conf <<EOF
# AmneziaWG server tunnel (created by awg-suite-installer)
# Obfuscation parameters below are sane defaults - regenerate for your fleet.
[Interface]
PrivateKey = ${awg_priv}
ListenPort = ${OPT_AWG_PORT}
Jc = 4
Jmin = 40
Jmax = 70
S1 = 76
S2 = 86
H1 = 1234567
H2 = 1234567
H3 = 1234567
H4 = 1234567
# Address = 10.11.0.1/24
EOF
    chmod 600 /etc/amnezia/amneziawg/awg0.conf
    SEEDED_AWG=1
    ok "Created /etc/amnezia/amneziawg/awg0.conf (UDP ${OPT_AWG_PORT}, fresh keypair + obfuscation params)."
  else
    ok "/etc/amnezia/amneziawg/awg0.conf already exists - left untouched."
  fi

  save_state
}

enable_tunnel_services() {
  hdr "Enabling tunnel services"
  if ! have_systemd; then
    warn "systemd not running - tunnels will not be started here."
    return 0
  fi
  if [ ! -e /dev/net/tun ]; then
    warn "/dev/net/tun missing - not starting tunnels now (they are enabled and"
    warn "will start on the next boot on a proper host/VM)."
  fi
  local started=()
  if [ -f /etc/wireguard/wg0.conf ]; then
    if systemctl enable wg-quick@wg0.service >/dev/null 2>&1; then
      started+=("wg-quick@wg0")
    else
      warn "Could not enable wg-quick@wg0.service (missing wg-quick@.service?)."
    fi
  fi
  if [ -f /etc/amnezia/amneziawg/awg0.conf ]; then
    if systemctl enable awg-quick@awg0.service >/dev/null 2>&1; then
      started+=("awg-quick@awg0")
    else
      warn "Could not enable awg-quick@awg0.service (missing awg-quick@.service?)."
    fi
  fi
  if [ "${#started[@]}" -gt 0 ] && [ -e /dev/net/tun ]; then
    systemctl start "${started[@]}" 2>/dev/null || warn "One or more tunnels failed to start - check: journalctl -u 'wg-quick@*' -u 'awg-quick@*'"
    ok "Enabled + started: ${started[*]}"
  elif [ "${#started[@]}" -gt 0 ]; then
    ok "Enabled: ${started[*]}"
  fi
}

# ------------------------------------------------------------------ sysctl / firewall
configure_sysctl() {
  hdr "Kernel forwarding (sysctl)"
  cat > "$SYSCTL_FILE" <<EOF
# Managed by awg-suite-installer.sh - forwarding for WG/AWG tunnels
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
  sysctl --system >/dev/null 2>&1 || warn "sysctl --system failed - forwarding may not be active until reboot."
  ok "Wrote ${SYSCTL_FILE} (IPv4 + IPv6 forwarding)."
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
  printf '  Next steps:\n'
  printf '    * Open the dashboard, log in (admin/admin) and SET A NEW PASSWORD.\n'
  printf '    * Add peers/tunnels from the dashboard, or edit the seeded configs.\n'
  printf '    * Tunnel services:  systemctl status wg-quick@wg0 awg-quick@awg0\n'
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
      if [ -n "$(git -C "$DASHBOARD_DIR" status --porcelain 2>/dev/null)" ]; then
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

  printf '\nDashboard URL: http://%s:%s (login: admin/admin unless changed)\n' "$PRIMARY_IP" "$OPT_DASH_PORT"
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
      --dashboard-port|--dashboard-bind|--wg-port|--awg-port|--awg-go-tag|--awg-tools-tag|--dashboard-tag|--go-version)
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
        esac
        shift 2 ;;
      --no-seed)         OPT_SEED=0; shift ;;
      --no-dashboard)    OPT_DASHBOARD=0; shift ;;
      --no-auto-update)  OPT_AUTO_UPDATE=0; shift ;;
      --force)           OPT_FORCE=1; shift ;;
      --no-self-update)  OPT_SELF_UPDATE=0; shift ;;
      --auto)            OPT_AUTO=1; shift ;;
      --purge)           OPT_PURGE=1; shift ;;
      --yes|-y)          OPT_YES=1; shift ;;
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
