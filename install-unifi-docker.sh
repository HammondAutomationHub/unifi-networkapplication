#!/usr/bin/env bash
#
# install-unifi-docker.sh
#
# Production installer / upgrader for UniFi Network Application + MongoDB via Docker Compose.
# Auto-detects an existing Docker install and upgrades in place (preserving data), or performs
# a clean fresh install when no legacy application is found.
# Targets Ubuntu/Debian-based systems (x86_64 and arm64 — tested on Khadas VIM4).
#
# Usage:
#   ./install-unifi-docker.sh [options]
#
# Options:
#   -d, --dir PATH           Install directory (default: $HOME/unifi)
#   -t, --tz TIMEZONE        Timezone, e.g. America/Los_Angeles (default: auto-detected, fallback UTC)
#       --unifi-tag TAG      lscr.io/linuxserver/unifi-network-application tag (default: latest)
#       --mongo-tag TAG      docker.io/mongo tag (default: 7.0 — see compatibility note below)
#       --network MODE       "bridge" (default) or "host"
#       --fresh              Force a fresh install (refuses if legacy data exists at --dir)
#       --migrate-from-deb   Automate native .deb -> Docker migration (backup, stop, restore)
#       --backup-file PATH   Use this .unf backup (optional; auto-detected if omitted)
#       --unifi-user USER    Native controller admin user (or env UNIFI_CTRL_USER)
#       --unifi-pass PASS    Native controller admin password (or env UNIFI_CTRL_PASS)
#       --disable-native-after  Disable native unifi.service after successful migration
#   -y, --yes                Non-interactive: accept all defaults, no confirmation prompt
#   -h, --help               Show this help text
#
# Safety features:
#   - Script lock prevents concurrent runs
#   - Pre-flight RAM/disk/port checks; aborts before destructive steps
#   - MongoDB major-version jump guard; post-upgrade log scan
#   - Dynamic MEM_LIMIT based on system RAM
#   - Graceful container stop order before backup (unifi -> unifi-db)
#
# Modes (automatic):
#   upgrade  Existing docker-compose install at --dir: backup, pull new images, verify data
#   fresh    No legacy install detected: new stack with generated credentials
#   blocked  Native .deb install or ambiguous legacy data: exits before any destructive step
#
# MongoDB / UniFi version compatibility (per linuxserver.io docs, check before pinning tags):
#   UniFi Network Application 8.1+  -> MongoDB 3.6 - 7.0
#   UniFi Network Application 9.0+  -> MongoDB 3.6 - 8.0
# Do not use "latest" for the mongo image in production — pin a version and only change it
# deliberately, since Mongo does not support skipping major versions on upgrade.
#
# Repo: <your-github-url-here>
# License: MIT

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.4.2"

# ----------------------------------------------------------------------------
# Defaults (overridable via flags)
# ----------------------------------------------------------------------------
INSTALL_DIR="${HOME}/unifi"
TZ_VALUE=""
UNIFI_TAG="latest"
MONGO_TAG="7.0"
UNIFI_TAG_CLI_SET=0
MONGO_TAG_CLI_SET=0
NETWORK_MODE="bridge"
NETWORK_MODE_CLI_SET=0
FORCE_FRESH=0
MIGRATE_FROM_DEB=0
ASSUME_YES=0
BACKUP_FILE=""
UNIFI_CTRL_USER="${UNIFI_CTRL_USER:-}"
UNIFI_CTRL_PASS="${UNIFI_CTRL_PASS:-}"
DISABLE_NATIVE_AFTER=0
MIGRATION_UNF=""
MIGRATION_RESTORE_OK=0
UNIFI_API="https://127.0.0.1:8443"

LOG_FILE="/tmp/unifi-install-$(date +%Y%m%d-%H%M%S).log"

# Runtime state (set during detection / upgrade)
INSTALL_MODE=""          # fresh | upgrade | blocked
LEGACY_REASON=""
BACKUP_ARCHIVE=""
BASELINE_FILE=""
MONGO_DATA_BYTES_BEFORE=0
ROLLBACK_ENABLED=0
SCRIPT_LOCK_ACQUIRED=0
SCRIPT_LOCK_FILE=""
STOPPED_UNATTENDED=0
UNIFI_MEM_LIMIT=1536
UNIFI_MEM_STARTUP=1024

# Minimum free disk (GB) required on the install volume
MIN_DISK_GB_FRESH=5
MIN_DISK_GB_BACKUP_EXTRA=2

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
COLOR_RESET="\033[0m"
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_DIM="\033[2m"

info()    { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET}  $*"; }
ok()      { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
warn()    { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
err()     { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2; }
detail()  { echo -e "${COLOR_DIM}[DETAIL]${COLOR_RESET} $*"; }
die()     { err "$*"; err "Full log: ${LOG_FILE}"; restore_unattended_upgrades; release_script_lock; exit 1; }

release_script_lock() {
  if [[ "${SCRIPT_LOCK_ACQUIRED}" -eq 1 ]]; then
    flock -u 200 2>/dev/null || true
    SCRIPT_LOCK_ACQUIRED=0
    detail "Released script lock: ${SCRIPT_LOCK_FILE}"
  fi
}

restore_unattended_upgrades() {
  if [[ "${STOPPED_UNATTENDED}" -eq 1 ]]; then
    sudo systemctl start unattended-upgrades 2>/dev/null || true
    STOPPED_UNATTENDED=0
    detail "Re-started unattended-upgrades service."
  fi
}

abort_data_loss() {
  err "DATA LOSS IMMINENT — aborting before making changes."
  err "$*"
  err "No containers were stopped and no files were modified by this script."
  err "Full log: ${LOG_FILE}"
  restore_unattended_upgrades
  release_script_lock
  exit 1
}

on_error() {
  trap - ERR
  local exit_code=$?
  local line_no=$1
  err "Script failed at line ${line_no} (exit code ${exit_code})."
  if [[ "${ROLLBACK_ENABLED}" -eq 1 && -n "${BACKUP_ARCHIVE}" && -f "${BACKUP_ARCHIVE}" ]]; then
    warn "Upgrade was in progress; attempting rollback from ${BACKUP_ARCHIVE}..."
    if rollback_from_backup; then
      warn "Rollback completed. Your previous install should be restored at ${INSTALL_DIR}."
    else
      err "Automatic rollback FAILED. Restore manually from: ${BACKUP_ARCHIVE}"
    fi
  else
    err "Install directory: ${INSTALL_DIR}"
    if [[ -n "${BACKUP_ARCHIVE}" && -f "${BACKUP_ARCHIVE}" ]]; then
      err "Backup archive (if created): ${BACKUP_ARCHIVE}"
    fi
  fi
  restore_unattended_upgrades
  release_script_lock
  err "Full log saved to: ${LOG_FILE}"
  exit "${exit_code}"
}
trap 'on_error ${LINENO}' ERR
trap 'restore_unattended_upgrades; release_script_lock' EXIT

# Mirror all script output to a log file for troubleshooting.
exec > >(tee -a "${LOG_FILE}") 2>&1

info "UniFi Docker installer v${SCRIPT_VERSION} started. Logging to ${LOG_FILE}"

# ----------------------------------------------------------------------------
# Usage / argument parsing
# ----------------------------------------------------------------------------
usage() {
  sed -n '2,/^set -Eeuo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir) INSTALL_DIR="$2"; shift 2 ;;
    -t|--tz) TZ_VALUE="$2"; shift 2 ;;
    --unifi-tag) UNIFI_TAG="$2"; UNIFI_TAG_CLI_SET=1; shift 2 ;;
    --mongo-tag) MONGO_TAG="$2"; MONGO_TAG_CLI_SET=1; shift 2 ;;
    --network) NETWORK_MODE="$2"; NETWORK_MODE_CLI_SET=1; shift 2 ;;
    --fresh) FORCE_FRESH=1; shift ;;
    --migrate-from-deb) MIGRATE_FROM_DEB=1; FORCE_FRESH=1; shift ;;
    --backup-file) BACKUP_FILE="$2"; shift 2 ;;
    --unifi-user) UNIFI_CTRL_USER="$2"; shift 2 ;;
    --unifi-pass) UNIFI_CTRL_PASS="$2"; shift 2 ;;
    --disable-native-after) DISABLE_NATIVE_AFTER=1; shift ;;
    -f|--force)
      warn "--force is deprecated and ignored. The script auto-detects upgrade vs fresh install."
      warn "Use --fresh to force a new install on an empty directory only."
      shift
      ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

if [[ "${NETWORK_MODE}" != "bridge" && "${NETWORK_MODE}" != "host" ]]; then
  die "--network must be 'bridge' or 'host', got: ${NETWORK_MODE}"
fi

INSTALL_DIR="$(realpath -m "${INSTALL_DIR}")"
detail "Resolved install directory: ${INSTALL_DIR}"

# ----------------------------------------------------------------------------
# Script lock (prevent concurrent installs/upgrades)
# ----------------------------------------------------------------------------
acquire_script_lock() {
  local lock_dir=""
  if [[ -d /run/lock && -w /run/lock ]]; then
    lock_dir="/run/lock"
  elif [[ -d /var/lock && -w /var/lock ]]; then
    lock_dir="/var/lock"
  else
    lock_dir="/tmp"
  fi
  SCRIPT_LOCK_FILE="${lock_dir}/unifi-docker-install.lock"
  require_cmd flock
  exec 200>"${SCRIPT_LOCK_FILE}"
  if ! flock -n 200; then
    local holder=""
    holder="$(cat "${SCRIPT_LOCK_FILE}" 2>/dev/null || true)"
    die "Another installer instance is already running (lock: ${SCRIPT_LOCK_FILE}${holder:+, pid=${holder}}). Wait for it to finish."
  fi
  echo "$$" >&200
  SCRIPT_LOCK_ACQUIRED=1
  ok "Acquired script lock: ${SCRIPT_LOCK_FILE} (pid=$$)"
}

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found. Install it and re-run."
}

acquire_script_lock

info "Running pre-flight checks..."

check_host_environment() {
  detail "Checking host environment (Docker-in-Docker / container restrictions)..."

  if [[ -f /.dockerenv ]]; then
    abort_data_loss "This script is running inside a Docker container. Run it on the host OS with Docker installed, not inside a container."
  fi

  if grep -sq '/docker/' /proc/1/cgroup 2>/dev/null && [[ ! -S /var/run/docker.sock ]] && ! sudo test -S /var/run/docker.sock 2>/dev/null; then
    abort_data_loss "Docker cgroup detected but /var/run/docker.sock is unavailable. Install Docker on the host or bind-mount the socket."
  fi

  if grep -sqE '(/lxc/|/lxd/)' /proc/1/cgroup 2>/dev/null; then
    warn "LXC/LXD container detected. UniFi + MongoDB in Docker requires a privileged-enough container with cgroup nesting."
    warn "If startup fails, run this script on bare metal or a VM instead."
  fi

  if grep -qi microsoft /proc/version 2>/dev/null; then
    warn "WSL detected. Ensure Docker Desktop integration or docker.io is running and systemd is enabled if needed."
  fi

  ok "Host environment check passed."
}

# curl -f fails on registry 401/404 even when the host is reachable — use explicit codes.
url_http_code() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$1" 2>/dev/null || echo "000"
}

url_is_reachable() {
  local url="$1"
  local expect="${2:-any}"
  local code
  code="$(url_http_code "${url}")"
  detail "HTTP ${code} from ${url}"

  case "${code}" in
    000)
      return 1
      ;;
  esac

  case "${expect}" in
    registry)
      # OCI/Docker registries often return 401 (auth required) or 404 on /v2/ — still reachable.
      case "${code}" in
        200|401|404) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    web)
      case "${code}" in
        2*|3*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    any)
      return 0
      ;;
  esac
}

check_dns_and_connectivity() {
  info "Checking network connectivity to Docker registries..."

  detail "Probing general HTTPS (hub.docker.com) ..."
  if ! url_is_reachable "https://hub.docker.com" "web"; then
    die "Could not reach https://hub.docker.com. Check DNS, firewall, and proxy settings."
  fi

  detail "Probing linuxserver registry (lscr.io/v2/) ..."
  if url_is_reachable "https://lscr.io/v2/" "registry"; then
    ok "linuxserver registry (lscr.io) appears reachable."
  else
    warn "Could not confirm HTTPS access to lscr.io/v2/ from this host."
    warn "Continuing — docker compose pull is the definitive test for the UniFi image."
    if command -v host >/dev/null 2>&1; then
      if host lscr.io >/dev/null 2>&1; then
        detail "DNS: lscr.io resolves ($(host lscr.io | head -1))"
      else
        warn "DNS lookup for lscr.io also failed. Ensure outbound HTTPS to lscr.io is allowed."
      fi
    fi
  fi

  detail "Probing Docker Hub registry (registry-1.docker.io/v2/) ..."
  if ! url_is_reachable "https://registry-1.docker.io/v2/" "registry"; then
    die "Could not reach https://registry-1.docker.io/v2/. Check DNS, firewall, and proxy settings."
  fi

  if command -v host >/dev/null 2>&1; then
    for ep in docker.io lscr.io ui.com; do
      detail "DNS lookup: ${ep}"
      if ! host "${ep}" >/dev/null 2>&1; then
        warn "DNS lookup failed for ${ep}. Installation may fail if resolution stays broken."
      fi
    done
  fi
  ok "Network connectivity confirmed."
}

disk_free_gb() {
  local path="$1"
  df -BG "${path}" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}'
}

check_system_resources() {
  local mem_total_mb mem_avail_mb mem_total_gb swap_total_mb disk_gb required_gb install_size_gb
  mem_total_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  mem_avail_mb="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)"
  mem_total_gb="$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)"
  swap_total_mb="$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)"

  detail "Memory: ${mem_total_mb} MB total (${mem_total_gb} GB), ${mem_avail_mb} MB available, swap ${swap_total_mb} MB"

  mkdir -p "$(dirname "${INSTALL_DIR}")" "${INSTALL_DIR}" 2>/dev/null || true
  disk_gb="$(disk_free_gb "$(dirname "${INSTALL_DIR}")")"
  detail "Free disk on install volume: ${disk_gb} GB ($(dirname "${INSTALL_DIR}"))"

  if [[ "${mem_total_mb}" -lt 1024 ]]; then
    abort_data_loss "System has less than 1 GB RAM (${mem_total_mb} MB). UniFi + MongoDB require at least 2 GB for stable operation."
  fi
  if [[ "${mem_total_mb}" -lt 2048 ]]; then
    warn "System RAM is below 2 GB (${mem_total_gb} GB). Performance may suffer; 4 GB+ is recommended."
    if [[ "${swap_total_mb}" -lt 512 ]]; then
      warn "Swap is minimal (${swap_total_mb} MB). Consider adding swap on low-memory boards (e.g. Khadas VIM 4)."
    fi
  fi

  required_gb="${MIN_DISK_GB_FRESH}"
  if [[ "${INSTALL_MODE}" == "upgrade" ]] && [[ -d "${INSTALL_DIR}" ]]; then
    install_size_gb="$(du -sBG "${INSTALL_DIR}" 2>/dev/null | awk '{gsub(/G/,"",$1); print $1}' || echo "0")"
    [[ "${install_size_gb}" =~ ^[0-9]+$ ]] || install_size_gb=0
    required_gb=$((install_size_gb + MIN_DISK_GB_BACKUP_EXTRA))
    if [[ "${required_gb}" -lt "${MIN_DISK_GB_FRESH}" ]]; then
      required_gb="${MIN_DISK_GB_FRESH}"
    fi
    detail "Upgrade requires ~${required_gb} GB free for backup (install dir ~${install_size_gb} GB + overhead)."
  fi

  if [[ ! "${disk_gb}" =~ ^[0-9]+$ ]] || [[ "${disk_gb}" -lt "${required_gb}" ]]; then
    abort_data_loss "Insufficient disk space on $(dirname "${INSTALL_DIR}"): ${disk_gb:-0} GB free, need at least ${required_gb} GB."
  fi

  ok "System resource check passed (${mem_total_gb} GB RAM, ${disk_gb} GB disk free)."
}

compute_memory_limits() {
  local mem_mb="${1:-}"
  if [[ -z "${mem_mb}" ]]; then
    mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  fi

  if [[ "${mem_mb}" -le 2048 ]]; then
    UNIFI_MEM_LIMIT=768
    UNIFI_MEM_STARTUP=512
  elif [[ "${mem_mb}" -le 4096 ]]; then
    UNIFI_MEM_LIMIT=1536
    UNIFI_MEM_STARTUP=1024
  else
    UNIFI_MEM_LIMIT=2048
    UNIFI_MEM_STARTUP=1536
  fi
  detail "Computed UniFi memory limits: MEM_LIMIT=${UNIFI_MEM_LIMIT} MB, MEM_STARTUP=${UNIFI_MEM_STARTUP} MB (MemTotal=${mem_mb} MB)."
}

port_is_listening() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tuln 2>/dev/null | grep -qE ":${port}[[:space:]]"
    return $?
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -tuln 2>/dev/null | grep -qE ":${port}[[:space:]]"
    return $?
  fi
  return 1
}

check_port_conflicts() {
  local port listener
  local ports=(8443 8080 8843 8880)
  info "Checking for port conflicts..."
  for port in "${ports[@]}"; do
    if port_is_listening "${port}"; then
      listener="$(ss -tulnp 2>/dev/null | grep -E ":${port}[[:space:]]" | head -1 || netstat -tulnp 2>/dev/null | grep -E ":${port}[[:space:]]" | head -1 || true)"
      if [[ "${INSTALL_MODE}" == "upgrade" ]]; then
        if echo "${listener}" | grep -qiE 'docker|unifi'; then
          detail "Port ${port} in use by existing Docker/UniFi stack (expected during upgrade)."
          continue
        fi
      fi
      err "Port ${port} is already in use:${listener:+ ${listener}}"
      abort_data_loss "Free port ${port} or stop the conflicting service before continuing."
    else
      detail "Port ${port} is available."
    fi
  done
  ok "Port conflict check passed."
}

mongo_major_from_tag() {
  local tag="$1"
  tag="${tag%%-*}"
  echo "${tag}" | cut -d. -f1 | tr -cd '0-9'
}

validate_mongo_tag_upgrade() {
  local installed_tag="$1"
  local target_tag="$2"
  local installed_major target_major jump

  [[ "${MONGO_TAG_CLI_SET}" -eq 1 ]] || return 0

  installed_major="$(mongo_major_from_tag "${installed_tag}")"
  target_major="$(mongo_major_from_tag "${target_tag}")"

  [[ -n "${installed_major}" && -n "${target_major}" ]] || {
    warn "Could not parse MongoDB major versions (installed=${installed_tag}, target=${target_tag}). Proceed with caution."
    return 0
  }

  detail "MongoDB major version change: ${installed_major}.x -> ${target_major}.x"

  if [[ "${target_major}" -lt "${installed_major}" ]]; then
    abort_data_loss "MongoDB downgrade from ${installed_tag} to ${target_tag} is not supported and would corrupt mongo-data/."
  fi

  jump=$((target_major - installed_major))
  if [[ "${jump}" -gt 1 ]]; then
    abort_data_loss "MongoDB cannot skip major versions (${installed_tag} -> ${target_tag}). Upgrade one major at a time (e.g. ${installed_major}.x -> $((installed_major + 1)).x first)."
  fi

  if [[ "${jump}" -eq 1 ]]; then
    warn "MongoDB major upgrade ${installed_major}.x -> ${target_major}.x requested."
    warn "Ensure you have a verified backup. The upgrade may take several minutes."
  fi

  ok "MongoDB tag change validated (${installed_tag} -> ${target_tag})."
}

scan_mongo_logs_for_errors() {
  local logs pattern_found line
  info "Scanning MongoDB container logs for upgrade/storage errors..."
  logs="$(docker_compose logs --no-color --tail 300 unifi-db 2>/dev/null || true)"
  if [[ -z "${logs}" ]]; then
    warn "No MongoDB logs available to scan."
    return 0
  fi
  pattern_found="$(echo "${logs}" | grep -iE \
    'too recent to start up on the existing data files|unsupported upgrade or downgrade|UPGRADE PROBLEM|Cannot start server with an unknown storage engine|unsupported WiredTiger file version|DBException in initAndListen, terminating' \
    | tail -5 || true)"
  if [[ -n "${pattern_found}" ]]; then
    err "MongoDB log indicates database storage/upgrade failure:"
    while IFS= read -r line; do
      err "  ${line}"
    done <<< "${pattern_found}"
    return 1
  fi
  ok "MongoDB log scan passed — no storage engine or upgrade errors detected."
  return 0
}

graceful_stop_for_backup() {
  info "Gracefully stopping containers for consistent backup (unifi -> unifi-db)..."
  if docker_compose_quiet ps --status running --services 2>/dev/null | grep -qx 'unifi'; then
    detail "Stopping unifi (timeout 60s)..."
    docker_compose stop -t 60 unifi
    ok "UniFi container stopped."
  fi
  if docker_compose_quiet ps --status running --services 2>/dev/null | grep -qx 'unifi-db'; then
    detail "Stopping unifi-db (timeout 30s)..."
    docker_compose stop -t 30 unifi-db
    ok "MongoDB container stopped."
  fi
}

check_host_environment

if [[ "${EUID}" -eq 0 ]]; then
  warn "Running as root. Docker-group membership steps will be skipped."
fi

if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
  warn "This script targets Ubuntu/Debian-based systems. /etc/os-release didn't match;"
  warn "continuing anyway, but apt-based steps may fail on your distro."
fi

ARCH="$(uname -m)"
info "Detected architecture: ${ARCH}"
case "${ARCH}" in
  x86_64|aarch64|arm64) ;;
  *) warn "Architecture ${ARCH} is not explicitly verified against linuxserver.io multi-arch images." ;;
esac
if [[ "${ARCH}" == "x86_64" ]]; then
  if ! grep -q avx /proc/cpuinfo 2>/dev/null; then
    warn "CPU does not report AVX. MongoDB >4.4 on x86_64 requires AVX."
    warn "If mongo crash-loops, pin --mongo-tag 4.4."
  fi
fi

require_cmd curl
require_cmd sudo
require_cmd awk
require_cmd tar
require_cmd realpath
require_cmd flock

check_dns_and_connectivity

# Auto-detect timezone if not supplied
if [[ -z "${TZ_VALUE}" ]]; then
  if command -v timedatectl >/dev/null 2>&1; then
    TZ_VALUE="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  fi
  if [[ -z "${TZ_VALUE}" && -f /etc/timezone ]]; then
    TZ_VALUE="$(cat /etc/timezone)"
  fi
  TZ_VALUE="${TZ_VALUE:-UTC}"
fi
info "Using timezone: ${TZ_VALUE} (override with --tz)"

PUID="$(id -u)"
PGID="$(id -g)"
info "Using PUID=${PUID} PGID=${PGID}"

# ----------------------------------------------------------------------------
# Docker helpers
# ----------------------------------------------------------------------------
docker_compose() {
  (cd "${INSTALL_DIR}" && sudo docker compose "$@")
}

docker_compose_quiet() {
  (cd "${INSTALL_DIR}" && sudo docker compose "$@" 2>/dev/null)
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker and Docker Compose plugin already installed."
    return 0
  fi

  if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
    info "Temporarily stopping unattended-upgrades to avoid apt lock conflicts..."
    if sudo systemctl stop unattended-upgrades 2>/dev/null; then
      STOPPED_UNATTENDED=1
      ok "Stopped unattended-upgrades for the duration of Docker installation."
    fi
  fi

  info "Installing Docker and Docker Compose plugin..."
  sudo apt-get update -y
  sudo apt-get install -y docker.io docker-compose-v2 curl openssl
  sudo systemctl enable --now docker
  ok "Docker installed."
  restore_unattended_upgrades

  if [[ "${EUID}" -ne 0 ]]; then
    if id -nG "${USER}" | grep -qw docker; then
      ok "User '${USER}' is already in the docker group."
    else
      info "Adding ${USER} to the docker group (effective after next login)..."
      sudo usermod -aG docker "${USER}"
      warn "This session uses 'sudo docker compose'. Log out/in to run docker without sudo."
    fi
  fi
}

# ----------------------------------------------------------------------------
# Legacy / install detection
# ----------------------------------------------------------------------------
has_mongo_data() {
  [[ -d "${INSTALL_DIR}/mongo-data" ]] || return 1
  [[ -n "$(find "${INSTALL_DIR}/mongo-data" -mindepth 1 -maxdepth 2 \
    \( -name 'WiredTiger' -o -name 'WiredTiger.wt' -o -name 'collection-*' -o -name 'index-*' \) \
    -print -quit 2>/dev/null)" ]]
}

has_unifi_config() {
  [[ -d "${INSTALL_DIR}/config" ]] || return 1
  [[ -n "$(find "${INSTALL_DIR}/config" -mindepth 1 -maxdepth 3 -type f -print -quit 2>/dev/null)" ]]
}

detect_native_unifi() {
  if command -v dpkg-query >/dev/null 2>&1; then
    if dpkg-query -W -f='${Status}' unifi 2>/dev/null | grep -q "install ok installed"; then
      return 0
    fi
  fi
  if [[ -d /usr/lib/unifi ]] && [[ -x /usr/sbin/unifi ]]; then
    return 0
  fi
  if systemctl list-unit-files 'unifi.service' 2>/dev/null | grep -q '^unifi.service'; then
    return 0
  fi
  return 1
}

detect_orphan_containers() {
  local running=0
  if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'unifi'; then
    running=1
    detail "Found running container: unifi"
  fi
  if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'unifi-db'; then
    running=1
    detail "Found running container: unifi-db"
  fi
  [[ "${running}" -eq 1 ]]
}

# ----------------------------------------------------------------------------
# Native .deb -> Docker migration (automated)
# ----------------------------------------------------------------------------
native_autobackup_dir() {
  local dir=""
  if [[ -f /usr/lib/unifi/data/system.properties ]]; then
    dir="$(grep -s '^autobackup.dir=' /usr/lib/unifi/data/system.properties | cut -d= -f2- | tr -d '\r')"
  fi
  if [[ -z "${dir}" ]]; then
    dir="/usr/lib/unifi/data/backup/autobackup"
  fi
  printf '%s' "${dir}"
}

find_latest_unf_in_dirs() {
  local dir unf
  for dir in "$@"; do
    [[ -d "${dir}" ]] || continue
    unf="$(find "${dir}" -maxdepth 3 -type f -name '*.unf' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    if [[ -n "${unf}" && -f "${unf}" ]]; then
      printf '%s' "${unf}"
      return 0
    fi
  done
  return 1
}

unifi_response_rc() {
  local body="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.meta.rc // empty' <<< "${body}" 2>/dev/null
    return 0
  fi
  grep -o '"rc"[[:space:]]*:[[:space:]]*"[^"]*"' <<< "${body}" | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

valid_unf_file() {
  local path="$1"
  [[ -f "${path}" && -s "${path}" ]] || return 1
  if head -c 64 "${path}" | grep -qiE 'DOCTYPE|<html'; then
    return 1
  fi
  return 0
}

unifi_api_login() {
  local base_url="$1" user="$2" pass="$3" cookie_jar="$4"
  local response rc
  response="$(curl -k -s -c "${cookie_jar}" -b "${cookie_jar}" \
    -X POST "${base_url}/api/login" \
    -H 'Content-Type: application/json' \
    --data "{\"username\":\"${user}\",\"password\":\"${pass}\"}" 2>/dev/null || true)"
  rc="$(unifi_response_rc "${response}")"
  [[ "${rc}" == "ok" ]]
}

download_native_api_backup() {
  local dest="$1" cookie_jar="$2"
  local http_code tmp
  tmp="$(mktemp)"
  http_code="$(curl -k -s -b "${cookie_jar}" -c "${cookie_jar}" \
    -X POST "${UNIFI_API}/api/s/default/cmd/backup" \
    -o "${dest}" -w '%{http_code}' 2>/dev/null || echo "000")"
  detail "Native API backup HTTP ${http_code} -> ${dest}"
  if [[ "${http_code}" != "200" ]] || ! valid_unf_file "${dest}"; then
    rm -f "${dest}"
    return 1
  fi
  ok "Created live .unf backup from native controller API."
  return 0
}

prepare_migration_backup() {
  local backup_dir unf age_days cookie_jar
  backup_dir="${INSTALL_DIR}/migration-backup"
  mkdir -p "${backup_dir}"
  cookie_jar="$(mktemp)"

  info "=== MIGRATION: locating or creating .unf backup ==="

  if [[ -n "${BACKUP_FILE}" ]]; then
    [[ -f "${BACKUP_FILE}" ]] || abort_data_loss "Backup file not found: ${BACKUP_FILE}"
    valid_unf_file "${BACKUP_FILE}" || abort_data_loss "File does not look like a valid .unf backup: ${BACKUP_FILE}"
    MIGRATION_UNF="${backup_dir}/selected-$(basename "${BACKUP_FILE}")"
    cp -a "${BACKUP_FILE}" "${MIGRATION_UNF}"
    ok "Using backup file: ${BACKUP_FILE}"
    rm -f "${cookie_jar}"
    return 0
  fi

  if [[ -n "${UNIFI_CTRL_USER}" && -n "${UNIFI_CTRL_PASS}" ]]; then
    if systemctl is-active --quiet unifi 2>/dev/null; then
      info "Creating fresh backup from running native controller via API..."
      MIGRATION_UNF="${backup_dir}/native-live-$(date +%Y%m%d-%H%M%S).unf"
      if unifi_api_login "${UNIFI_API}" "${UNIFI_CTRL_USER}" "${UNIFI_CTRL_PASS}" "${cookie_jar}" \
        && download_native_api_backup "${MIGRATION_UNF}" "${cookie_jar}"; then
        rm -f "${cookie_jar}"
        return 0
      fi
      warn "Live API backup failed (wrong credentials or API unavailable)."
    else
      warn "Native unifi service is not running; skipping live API backup."
    fi
  fi

  unf="$(find_latest_unf_in_dirs "$(native_autobackup_dir)" /usr/lib/unifi/data/backup "${INSTALL_DIR}/migration-backup")" || true
  if [[ -n "${unf}" ]] && valid_unf_file "${unf}"; then
    age_days=$(( ( $(date +%s) - $(stat -c %Y "${unf}") ) / 86400 ))
    MIGRATION_UNF="${backup_dir}/autobackup-$(basename "${unf}")"
    cp -a "${unf}" "${MIGRATION_UNF}"
    if [[ "${age_days}" -gt 1 ]]; then
      warn "Latest autobackup is ${age_days} day(s) old: ${unf}"
      warn "For best results, provide --unifi-user/--unifi-pass for a live backup."
    fi
    ok "Using native autobackup: ${unf}"
    rm -f "${cookie_jar}"
    return 0
  fi

  rm -f "${cookie_jar}"
  abort_data_loss "No .unf backup found. Provide one of:
  - --backup-file /path/to/backup.unf
  - --unifi-user USER --unifi-pass PASS (while native unifi is running)
  - Enable autobackup on the native controller and wait for a backup in $(native_autobackup_dir)"
}

stop_native_unifi_service() {
  info "Stopping native UniFi service..."
  if systemctl is-active --quiet unifi 2>/dev/null; then
    if ! systemctl stop unifi; then
      abort_data_loss "Failed to stop native unifi service. Run: sudo systemctl stop unifi"
    fi
    sleep 2
  fi
  if systemctl is-active --quiet unifi 2>/dev/null; then
    abort_data_loss "Native unifi service is still active after stop request."
  fi
  ok "Native unifi service stopped."
}

wait_for_unifi_api() {
  local i code
  info "Waiting for UniFi API on ${UNIFI_API}..."
  for i in $(seq 1 90); do
    code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 3 "${UNIFI_API}/status" 2>/dev/null || echo "000")"
    if [[ "${code}" =~ ^(200|204|302)$ ]]; then
      ok "UniFi API is responding (HTTP ${code})."
      return 0
    fi
    detail "UniFi API not ready (HTTP ${code:-none}, attempt ${i}/90)..."
    sleep 5
  done
  return 1
}

restore_unf_via_api() {
  local unf="$1" response http_code rc cookie_jar
  info "Uploading .unf backup to Docker UniFi controller..."
  detail "Backup file: ${unf} ($(du -h "${unf}" | awk '{print $1}'))"

  response="$(mktemp)"
  http_code="$(curl -k -s -w '%{http_code}' -o "${response}" \
    -X POST "${UNIFI_API}/api/s/default/cmd/restore" \
    -F "file=@${unf}" 2>/dev/null || echo "000")"
  detail "Restore upload HTTP ${http_code}"
  rc="$(unifi_response_rc "$(cat "${response}" 2>/dev/null)")"
  rm -f "${response}"

  if [[ "${http_code}" == "200" && "${rc}" == "ok" ]]; then
    ok "Restore accepted by controller — waiting for restart..."
    return 0
  fi

  if [[ -n "${UNIFI_CTRL_USER}" && -n "${UNIFI_CTRL_PASS}" ]]; then
    cookie_jar="$(mktemp)"
    if unifi_api_login "${UNIFI_API}" "${UNIFI_CTRL_USER}" "${UNIFI_CTRL_PASS}" "${cookie_jar}"; then
      response="$(mktemp)"
      http_code="$(curl -k -s -b "${cookie_jar}" -c "${cookie_jar}" -w '%{http_code}' -o "${response}" \
        -X POST "${UNIFI_API}/api/s/default/cmd/restore" \
        -F "file=@${unf}" 2>/dev/null || echo "000")"
      rc="$(unifi_response_rc "$(cat "${response}" 2>/dev/null)")"
      rm -f "${response}" "${cookie_jar}"
      if [[ "${http_code}" == "200" && "${rc}" == "ok" ]]; then
        ok "Restore accepted (authenticated upload)."
        return 0
      fi
    fi
    rm -f "${cookie_jar}"
  fi

  warn "Automatic .unf restore via API did not succeed."
  return 1
}

wait_after_restore() {
  info "Waiting for controller to finish restore (may take several minutes)..."
  sleep 15
  wait_for_unifi_api || return 1
  sleep 10
  wait_for_unifi_web || true
  return 0
}

configure_inform_host_via_api() {
  local host_ip="$1" cookie_jar response rc
  [[ -n "${UNIFI_CTRL_USER}" && -n "${UNIFI_CTRL_PASS}" ]] || {
    warn "Skipping Inform Host API step (--unifi-user/--unifi-pass not set)."
    return 1
  }

  cookie_jar="$(mktemp)"
  info "Setting Inform Host to ${host_ip} via API..."
  if ! unifi_api_login "${UNIFI_API}" "${UNIFI_CTRL_USER}" "${UNIFI_CTRL_PASS}" "${cookie_jar}"; then
    warn "Could not log in to Docker controller after restore (credentials must match the backup)."
    rm -f "${cookie_jar}"
    return 1
  fi

  response="$(curl -k -s -b "${cookie_jar}" -c "${cookie_jar}" \
    -X PUT "${UNIFI_API}/api/s/default/set/setting/system" \
    -H 'Content-Type: application/json' \
    --data "{\"inform_host\":\"${host_ip}\",\"inform_host_override\":true}" 2>/dev/null || true)"
  rc="$(unifi_response_rc "${response}")"
  rm -f "${cookie_jar}"

  if [[ "${rc}" == "ok" ]]; then
    ok "Inform Host set to ${host_ip} (override enabled)."
    return 0
  fi
  warn "Inform Host API update failed (rc=${rc:-unknown}). Set it manually in the web UI."
  return 1
}

run_migration_post_install() {
  local host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  host_ip="${host_ip:-127.0.0.1}"

  wait_for_unifi_api || {
    warn "UniFi API not ready — restore must be completed manually with: ${MIGRATION_UNF}"
    return 1
  }

  if restore_unf_via_api "${MIGRATION_UNF}"; then
    wait_after_restore
    configure_inform_host_via_api "${host_ip}" || true
    MIGRATION_RESTORE_OK=1
    ok "Automated migration restore completed."
  else
    warn "Manual restore required in the web UI using: ${MIGRATION_UNF}"
    return 1
  fi

  if [[ "${DISABLE_NATIVE_AFTER}" -eq 1 ]]; then
    info "Disabling native unifi.service..."
    systemctl disable unifi 2>/dev/null || true
    ok "Native unifi.service disabled (Docker controller is now primary)."
  fi
}

detect_installation() {
  detail "Scanning for existing UniFi installations..."

  if detect_native_unifi; then
    if [[ "${MIGRATE_FROM_DEB}" -eq 1 ]]; then
      INSTALL_MODE="fresh"
      LEGACY_REASON="native_deb_migrate"
      ok "Automated migration mode: native .deb -> Docker at ${INSTALL_DIR}."
      detail "Will backup, stop native service, install Docker, and restore .unf via API."
      return 0
    fi
    if [[ "${FORCE_FRESH}" -eq 1 ]]; then
      INSTALL_MODE="fresh"
      LEGACY_REASON="native_deb_migrate"
      warn "Native .deb UniFi detected. --fresh installs a new Docker controller at ${INSTALL_DIR}."
      warn "Native data is NOT migrated automatically — restore from a .unf backup after install."
      detail "Stop native UniFi before continuing: sudo systemctl stop unifi"
      ok "Migration mode: fresh Docker install (requires .unf restore in web wizard)."
      return 0
    fi
    INSTALL_MODE="blocked"
    LEGACY_REASON="native_deb"
    warn "Detected native UniFi Network Application (.deb package) on this host."
    detail "Paths checked: dpkg package 'unifi', /usr/lib/unifi, unifi.service"
    return 0
  fi

  if [[ -f "${INSTALL_DIR}/docker-compose.yml" && -f "${INSTALL_DIR}/.env" ]]; then
    if has_mongo_data || has_unifi_config; then
      INSTALL_MODE="upgrade"
      LEGACY_REASON="docker_compose"
      ok "Detected existing Docker Compose install at ${INSTALL_DIR} (will upgrade in place)."
      return 0
    fi
    INSTALL_MODE="upgrade"
    LEGACY_REASON="docker_compose_empty_data"
    warn "Docker Compose install found at ${INSTALL_DIR} but data dirs look empty/new."
    detail "Proceeding as upgrade to preserve .env and compose layout."
    return 0
  fi

  if [[ -f "${INSTALL_DIR}/docker-compose.yml" && ! -f "${INSTALL_DIR}/.env" ]]; then
    INSTALL_MODE="blocked"
    LEGACY_REASON="compose_without_env"
    err "Found docker-compose.yml at ${INSTALL_DIR} but no .env file."
    err "Mongo credentials cannot be recovered automatically — proceeding would risk data loss."
    return 0
  fi

  if has_mongo_data; then
    INSTALL_MODE="blocked"
    LEGACY_REASON="orphan_mongo_data"
    err "Found MongoDB data at ${INSTALL_DIR}/mongo-data without a matching docker-compose.yml + .env."
    err "Cannot safely attach new credentials to existing database files."
    return 0
  fi

  if has_unifi_config; then
    INSTALL_MODE="blocked"
    LEGACY_REASON="orphan_config"
    err "Found UniFi config data at ${INSTALL_DIR}/config without docker-compose.yml + .env."
    err "Restore the full install directory or place backup files consistently before re-running."
    return 0
  fi

  if detect_orphan_containers; then
    INSTALL_MODE="blocked"
    LEGACY_REASON="orphan_containers"
    err "Found running unifi/unifi-db containers not managed by ${INSTALL_DIR}/docker-compose.yml."
    err "Stop those containers manually or point --dir at the correct install directory."
    return 0
  fi

  if [[ -d "${INSTALL_DIR}" && -n "$(find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    if [[ "${FORCE_FRESH}" -eq 1 ]]; then
      INSTALL_MODE="blocked"
      LEGACY_REASON="non_empty_dir"
      err "Install directory ${INSTALL_DIR} is not empty but no recognizable UniFi install was found."
      err "Use an empty directory or remove unrelated files before --fresh."
      return 0
    fi
    warn "Install directory exists but appears empty of UniFi data; fresh install will reuse the directory."
  fi

  INSTALL_MODE="fresh"
  LEGACY_REASON="none"
  ok "No existing UniFi application detected — fresh install."
}

report_blocked_legacy() {
  echo ""
  echo "================================================================"
  echo " Cannot proceed automatically — manual migration required"
  echo "================================================================"
  case "${LEGACY_REASON}" in
    native_deb)
      echo " A native (.deb) UniFi controller is installed on this system."
      echo " Automated in-place upgrade to Docker is NOT supported (different data layout)."
      echo ""
      echo " Safe migration steps:"
      echo "   1. Open the existing controller web UI."
      echo "   2. Settings -> System -> Backup -> Download backup (.unf)."
      echo "   3. Stop the native service: sudo systemctl stop unifi"
      echo "   4. Automated migration (recommended):"
      echo "        UNIFI_CTRL_USER=admin UNIFI_CTRL_PASS='your-password' \\"
      echo "          ./install-unifi-docker.sh --migrate-from-deb -y"
      echo "   Or manual Docker install after backup:"
      echo "        ./install-unifi-docker.sh --fresh -y"
      echo "   5. In the new install wizard: Restore from backup (.unf)."
      echo "   6. Settings -> System -> Advanced -> set Inform Host and enable Override."
      ;;
    native_deb_migrate)
      echo " (This message should not appear — migration mode proceeds automatically.)"
      ;;
    compose_without_env|orphan_mongo_data|orphan_config)
      echo " Legacy data was found but credentials or compose metadata are missing."
      echo " Restore ${INSTALL_DIR}/.env from your backups before re-running."
      echo " If you only have a .unf backup, use --fresh on an empty directory and restore via the UI."
      ;;
    orphan_containers)
      echo " Stop unrelated UniFi containers first:"
      echo "   sudo docker stop unifi unifi-db"
      echo " Then re-run with --dir pointing at the correct install path."
      ;;
    non_empty_dir)
      echo " Choose an empty install path: ./install-unifi-docker.sh --dir /path/to/empty/unifi --fresh"
      ;;
    *)
      echo " Unrecognized legacy state. See log: ${LOG_FILE}"
      ;;
  esac
  echo "================================================================"
}

# ----------------------------------------------------------------------------
# Environment / compose file writers
# ----------------------------------------------------------------------------
load_env_file() {
  # shellcheck disable=SC1091
  set -a
  source "${INSTALL_DIR}/.env"
  set +a
  detail "Loaded existing .env (Mongo user=${MONGO_APP_USER}, db=${MONGO_DBNAME})."
}

validate_env_file() {
  local required_vars=(MONGO_ROOT_USER MONGO_ROOT_PASS MONGO_APP_USER MONGO_APP_PASS MONGO_DBNAME MONGO_AUTHSOURCE)
  local var
  for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      abort_data_loss "Required variable ${var} is missing or empty in ${INSTALL_DIR}/.env"
    fi
  done
  ok "Existing .env contains all required MongoDB credentials."
}

gen_secret() {
  require_cmd openssl
  openssl rand -base64 24 | tr -d '/+=' | cut -c1-24
}

apply_upgrade_tag_defaults() {
  load_env_file
  validate_env_file

  if [[ "${UNIFI_TAG_CLI_SET}" -eq 0 ]]; then
    UNIFI_TAG="latest"
    detail "UniFi tag not specified on CLI; upgrading to: latest"
  fi
  if [[ "${MONGO_TAG_CLI_SET}" -eq 0 ]]; then
    detail "Mongo tag not specified on CLI; preserving installed tag: ${MONGO_TAG}"
  else
    warn "Mongo tag explicitly changed to ${MONGO_TAG}."
    warn "MongoDB major-version jumps require a planned migration — verify compatibility before continuing."
  fi

  if [[ "${NETWORK_MODE_CLI_SET}" -eq 0 && -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
    if grep -q 'network_mode: "host"' "${INSTALL_DIR}/docker-compose.yml"; then
      NETWORK_MODE="host"
    else
      NETWORK_MODE="bridge"
    fi
    detail "Preserving network mode from existing install: ${NETWORK_MODE}"
  fi
}

write_env_file() {
  local mode="$1"
  MONGO_ROOT_USER="root"
  MONGO_APP_USER="unifi"
  MONGO_DBNAME="unifi"
  MONGO_AUTHSOURCE="admin"

  if [[ "${mode}" == "fresh" ]]; then
    MONGO_ROOT_PASS="$(gen_secret)"
    MONGO_APP_PASS="$(gen_secret)"
    detail "Generated new MongoDB credentials for fresh install."
  else
    apply_upgrade_tag_defaults
    detail "Preserving existing MongoDB credentials for upgrade."
  fi

  # Update image tags and runtime IDs; never rotate passwords on upgrade.
  cat > "${INSTALL_DIR}/.env" << EOF
TZ=${TZ_VALUE}
PUID=${PUID}
PGID=${PGID}
UNIFI_TAG=${UNIFI_TAG}
MONGO_TAG=${MONGO_TAG}
MONGO_ROOT_USER=${MONGO_ROOT_USER}
MONGO_ROOT_PASS=${MONGO_ROOT_PASS}
MONGO_APP_USER=${MONGO_APP_USER}
MONGO_APP_PASS=${MONGO_APP_PASS}
MONGO_DBNAME=${MONGO_DBNAME}
MONGO_AUTHSOURCE=${MONGO_AUTHSOURCE}
EOF
  chmod 600 "${INSTALL_DIR}/.env"
  load_env_file
  ok ".env written (mode=${mode}, chmod 600)."
}

write_compose_files() {
  mkdir -p "${INSTALL_DIR}/config" "${INSTALL_DIR}/mongo-data"

  cat > "${INSTALL_DIR}/init-mongo.sh" << 'EOF'
#!/bin/bash
set -e
mongosh <<MONGOSCRIPT
db = db.getSiblingDB('admin')
db.auth('${MONGO_INITDB_ROOT_USERNAME}', '${MONGO_INITDB_ROOT_PASSWORD}')
db = db.getSiblingDB('${MONGO_DBNAME}')
db.createUser({
  user: '${MONGO_USER}',
  pwd: '${MONGO_PASS}',
  roles: [ { role: 'dbOwner', db: '${MONGO_DBNAME}' } ]
})
MONGOSCRIPT
EOF
  chmod +x "${INSTALL_DIR}/init-mongo.sh"
  detail "init-mongo.sh written (runs only when mongo-data is empty)."

  local ports_block="" network_block_unifi=""
  if [[ "${NETWORK_MODE}" == "host" ]]; then
    network_block_unifi=$'    network_mode: "host"\n'
  else
    ports_block=$'    ports:\n      - "8443:8443"\n      - "3478:3478/udp"\n      - "10001:10001/udp"\n      - "8080:8080"\n      - "1900:1900/udp"\n      - "8843:8843"\n      - "8880:8880"\n'
  fi

  cat > "${INSTALL_DIR}/docker-compose.yml" << EOF
services:
  unifi-db:
    image: docker.io/mongo:\${MONGO_TAG}
    container_name: unifi-db
    environment:
      - MONGO_INITDB_ROOT_USERNAME=\${MONGO_ROOT_USER}
      - MONGO_INITDB_ROOT_PASSWORD=\${MONGO_ROOT_PASS}
      - MONGO_USER=\${MONGO_APP_USER}
      - MONGO_PASS=\${MONGO_APP_PASS}
      - MONGO_DBNAME=\${MONGO_DBNAME}
      - MONGO_AUTHSOURCE=\${MONGO_AUTHSOURCE}
    volumes:
      - ./mongo-data:/data/db
      - ./init-mongo.sh:/docker-entrypoint-initdb.d/init-mongo.sh:ro
    healthcheck:
      test: ["CMD-SHELL", "mongosh --quiet -u \"$$MONGO_INITDB_ROOT_USERNAME\" -p \"$$MONGO_INITDB_ROOT_PASSWORD\" --authenticationDatabase admin --eval 'db.adminCommand(\"ping\").ok' || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    restart: unless-stopped

  unifi:
    image: lscr.io/linuxserver/unifi-network-application:\${UNIFI_TAG}
    container_name: unifi
${network_block_unifi}    depends_on:
      unifi-db:
        condition: service_healthy
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
      - MONGO_USER=\${MONGO_APP_USER}
      - MONGO_PASS=\${MONGO_APP_PASS}
      - MONGO_HOST=unifi-db
      - MONGO_PORT=27017
      - MONGO_DBNAME=\${MONGO_DBNAME}
      - MONGO_AUTHSOURCE=\${MONGO_AUTHSOURCE}
      - MEM_LIMIT=${UNIFI_MEM_LIMIT}
      - MEM_STARTUP=${UNIFI_MEM_STARTUP}
    volumes:
      - ./config:/config
${ports_block}    restart: unless-stopped
EOF
  ok "docker-compose.yml written (network=${NETWORK_MODE})."
}

# ----------------------------------------------------------------------------
# Backup / baseline / verification
# ----------------------------------------------------------------------------
measure_mongo_data_bytes() {
  if [[ -d "${INSTALL_DIR}/mongo-data" ]]; then
    du -sb "${INSTALL_DIR}/mongo-data" 2>/dev/null | awk '{print $1}'
  else
    echo "0"
  fi
}

create_backup_archive() {
  local backup_root
  backup_root="$(dirname "${INSTALL_DIR}")/unifi-backups"
  mkdir -p "${backup_root}"
  BACKUP_ARCHIVE="${backup_root}/unifi-pre-upgrade-$(date +%Y%m%d-%H%M%S).tar.gz"

  info "Creating full backup archive before upgrade..."
  detail "Source: ${INSTALL_DIR}"
  detail "Target: ${BACKUP_ARCHIVE}"

  tar -czf "${BACKUP_ARCHIVE}" -C "$(dirname "${INSTALL_DIR}")" "$(basename "${INSTALL_DIR}")"
  ok "Backup archive created: ${BACKUP_ARCHIVE} ($(du -h "${BACKUP_ARCHIVE}" | awk '{print $1}'))"
}

rollback_from_backup() {
  if [[ ! -f "${BACKUP_ARCHIVE}" ]]; then
    err "Rollback archive not found: ${BACKUP_ARCHIVE}"
    return 1
  fi

  info "Rolling back from ${BACKUP_ARCHIVE}..."
  docker_compose down --timeout 30 || true

  local parent base staging
  parent="$(dirname "${INSTALL_DIR}")"
  base="$(basename "${INSTALL_DIR}")"
  staging="${parent}/${base}.rollback-staging.$(date +%Y%m%d-%H%M%S)"

  if [[ -d "${INSTALL_DIR}" ]]; then
    detail "Moving current (failed) install to ${staging}"
    mv "${INSTALL_DIR}" "${staging}"
  fi

  mkdir -p "${INSTALL_DIR}"
  tar -xzf "${BACKUP_ARCHIVE}" -C "${parent}"
  ok "Restored install directory from backup."

  docker_compose up -d
  return 0
}

mongo_collections_to_check() {
  echo "device site admin setting user group wlan_conf networkconf"
}

capture_mongo_baseline() {
  BASELINE_FILE="${INSTALL_DIR}/.unifi-mongo-baseline.$(date +%Y%m%d-%H%M%S).txt"
  info "Capturing MongoDB document baseline (pre-upgrade)..."

  if ! docker_compose_quiet ps --status running --services | grep -qx 'unifi-db'; then
    detail "unifi-db not running; starting stack briefly for baseline capture..."
    docker_compose up -d unifi-db
    wait_for_mongo_healthy
  fi

  local coll counts total
  counts=""
  total=0
  for coll in $(mongo_collections_to_check); do
    local count
    count="$(docker_compose exec -T unifi-db mongosh --quiet \
      -u "${MONGO_ROOT_USER}" -p "${MONGO_ROOT_PASS}" --authenticationDatabase admin \
      --eval "db.getSiblingDB('${MONGO_DBNAME}').getCollection('${coll}').countDocuments()" 2>/dev/null | tr -d '\r' || echo "ERR")"
    if [[ "${count}" == "ERR" || ! "${count}" =~ ^[0-9]+$ ]]; then
      count="0"
      detail "Collection '${coll}': unavailable or empty (treated as 0)."
    else
      detail "Collection '${coll}': ${count} document(s)."
    fi
    counts+="${coll}=${count}"$'\n'
    total=$((total + count))
  done

  MONGO_DATA_BYTES_BEFORE="$(measure_mongo_data_bytes)"
  {
    echo "# UniFi MongoDB baseline captured $(date -Iseconds)"
    echo "mongo_data_bytes=${MONGO_DATA_BYTES_BEFORE}"
    echo "total_documents=${total}"
    printf '%s' "${counts}"
  } > "${BASELINE_FILE}"

  ok "Baseline saved to ${BASELINE_FILE} (total documents=${total}, mongo-data=${MONGO_DATA_BYTES_BEFORE} bytes)."
}

verify_mongo_baseline() {
  info "Verifying MongoDB data integrity (post-upgrade)..."
  [[ -f "${BASELINE_FILE}" ]] || abort_data_loss "Baseline file missing — cannot verify data preservation."

  # shellcheck disable=SC1090
  source "${BASELINE_FILE}"

  wait_for_mongo_healthy

  local failures=0
  local coll baseline_count current_count
  for coll in $(mongo_collections_to_check); do
    baseline_count="$(grep -E "^${coll}=" "${BASELINE_FILE}" | cut -d= -f2 || echo "0")"
    current_count="$(docker_compose exec -T unifi-db mongosh --quiet \
      -u "${MONGO_ROOT_USER}" -p "${MONGO_ROOT_PASS}" --authenticationDatabase admin \
      --eval "db.getSiblingDB('${MONGO_DBNAME}').getCollection('${coll}').countDocuments()" 2>/dev/null | tr -d '\r' || echo "ERR")"

    if [[ ! "${current_count}" =~ ^[0-9]+$ ]]; then
      err "Could not read collection '${coll}' after upgrade."
      failures=$((failures + 1))
      continue
    fi

    detail "Collection '${coll}': before=${baseline_count} after=${current_count}"
    if [[ "${current_count}" -lt "${baseline_count}" ]]; then
      err "DATA LOSS DETECTED in collection '${coll}': ${baseline_count} -> ${current_count}"
      failures=$((failures + 1))
    fi
  done

  local bytes_after
  bytes_after="$(measure_mongo_data_bytes)"
  detail "mongo-data size: before=${MONGO_DATA_BYTES_BEFORE} bytes after=${bytes_after} bytes"
  if [[ "${bytes_after}" -lt "${MONGO_DATA_BYTES_BEFORE}" ]]; then
    err "DATA LOSS DETECTED: mongo-data directory shrank (${MONGO_DATA_BYTES_BEFORE} -> ${bytes_after} bytes)."
    failures=$((failures + 1))
  fi

  if [[ "${failures}" -gt 0 ]]; then
    err "MongoDB verification failed with ${failures} issue(s)."
    return 1
  fi

  ok "MongoDB verification passed — no document count or size regression detected."
  return 0
}

verify_config_preserved() {
  info "Verifying UniFi config volume..."
  if has_unifi_config; then
    local file_count
    file_count="$(find "${INSTALL_DIR}/config" -type f 2>/dev/null | wc -l | tr -d ' ')"
    detail "config/ contains ${file_count} file(s)."
    ok "UniFi config directory present after upgrade."
  else
    detail "config/ is empty or new (expected for uninitialized controller)."
  fi
}

wait_for_mongo_healthy() {
  info "Waiting for MongoDB to become healthy..."
  local i state
  for i in $(seq 1 36); do
    state="$(docker_compose_quiet ps --format json unifi-db 2>/dev/null | grep -o '"Health":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    if [[ "${state}" == "healthy" ]]; then
      ok "MongoDB is healthy."
      return 0
    fi
    if docker_compose_quiet ps --status running --services | grep -qx 'unifi-db'; then
      if docker_compose exec -T unifi-db mongosh --quiet \
        -u "${MONGO_ROOT_USER}" -p "${MONGO_ROOT_PASS}" --authenticationDatabase admin \
        --eval 'db.adminCommand("ping").ok' 2>/dev/null | grep -q '1'; then
        ok "MongoDB responded to authenticated ping."
        return 0
      fi
    fi
    detail "MongoDB not ready yet (attempt ${i}/36)..."
    sleep 5
  done
  abort_data_loss "MongoDB did not become healthy within 3 minutes."
}

ensure_native_unifi_stopped_for_migration() {
  [[ "${LEGACY_REASON}" == "native_deb_migrate" ]] || return 0

  if [[ "${MIGRATE_FROM_DEB}" -eq 1 ]]; then
    stop_native_unifi_service
  elif systemctl is-active --quiet unifi 2>/dev/null; then
    abort_data_loss "Native unifi service is still running. Use --migrate-from-deb to stop it automatically, or run: sudo systemctl stop unifi"
  fi

  if port_is_listening 8443; then
    abort_data_loss "Port 8443 is still in use by another process. Free the port before continuing."
  fi
  ok "Port 8443 is available for the Docker install."
}

wait_for_unifi_web() {
  info "Waiting for UniFi web UI (https://localhost:8443)..."
  local i code
  for i in $(seq 1 60); do
    code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 3 https://localhost:8443 2>/dev/null || true)"
    if [[ "${code}" == "200" || "${code}" == "302" || "${code}" == "401" ]]; then
      ok "UniFi web UI is responding (HTTP ${code})."
      return 0
    fi
    detail "UniFi not ready yet (HTTP ${code:-none}, attempt ${i}/60)..."
    sleep 5
  done
  warn "UniFi did not respond within 5 minutes. It may still be starting."
  warn "Check: cd ${INSTALL_DIR} && sudo docker compose logs -f unifi"
  return 1
}

confirm_proceed() {
  echo ""
  echo "=== UniFi Network Application Docker Installer ==="
  echo "  Mode               : ${INSTALL_MODE}"
  echo "  Install directory  : ${INSTALL_DIR}"
  echo "  Timezone           : ${TZ_VALUE}"
  echo "  UniFi image tag    : ${UNIFI_TAG}"
  echo "  Mongo image tag    : ${MONGO_TAG}"
  echo "  Network mode       : ${NETWORK_MODE}"
  if [[ "${INSTALL_MODE}" == "upgrade" ]]; then
    echo "  Data handling      : backup + in-place upgrade (credentials preserved)"
  elif [[ "${LEGACY_REASON}" == "native_deb_migrate" || "${MIGRATE_FROM_DEB}" -eq 1 ]]; then
    echo "  Migration          : automated native .deb -> Docker (.unf restore via API)"
  fi
  echo "  UniFi memory limit : ${UNIFI_MEM_LIMIT} MB (MEM_STARTUP=${UNIFI_MEM_STARTUP} MB)"
  echo ""
  if [[ "${ASSUME_YES}" -ne 1 ]]; then
    read -r -p "Proceed? [y/N] " reply
    [[ "${reply}" =~ ^[Yy]$ ]] || { info "Aborted by user."; exit 0; }
  fi
}

# ----------------------------------------------------------------------------
# Fresh install
# ----------------------------------------------------------------------------
run_fresh_install() {
  info "=== FRESH INSTALL MODE ==="

  if [[ "${FORCE_FRESH}" -eq 0 && "${INSTALL_MODE}" != "fresh" ]]; then
    abort_data_loss "Internal error: fresh install requested but mode=${INSTALL_MODE}"
  fi

  if has_mongo_data; then
    abort_data_loss "mongo-data already exists at ${INSTALL_DIR}/mongo-data. Use upgrade mode or remove data intentionally."
  fi

  if [[ "${MIGRATE_FROM_DEB}" -eq 1 ]]; then
    prepare_migration_backup
  fi

  mkdir -p "${INSTALL_DIR}"
  ensure_native_unifi_stopped_for_migration
  check_port_conflicts
  write_env_file "fresh"
  write_compose_files

  info "Pulling container images..."
  docker_compose pull

  info "Starting containers..."
  docker_compose up -d

  wait_for_mongo_healthy
  scan_mongo_logs_for_errors || warn "MongoDB log scan reported issues on fresh install — check: docker compose logs unifi-db"
  wait_for_unifi_web || true

  if [[ "${MIGRATE_FROM_DEB}" -eq 1 ]]; then
    run_migration_post_install || warn "Docker is installed; complete restore manually if needed."
  fi

  print_summary "fresh"
}

# ----------------------------------------------------------------------------
# Upgrade
# ----------------------------------------------------------------------------
run_upgrade() {
  info "=== UPGRADE MODE ==="
  ROLLBACK_ENABLED=1

  load_env_file
  validate_env_file

  local old_unifi_tag old_mongo_tag
  old_unifi_tag="${UNIFI_TAG:-unknown}"
  old_mongo_tag="${MONGO_TAG:-unknown}"
  detail "Installed tags from .env: UNIFI_TAG=${old_unifi_tag} MONGO_TAG=${old_mongo_tag}"
  if [[ "${UNIFI_TAG_CLI_SET}" -eq 1 ]]; then
    detail "CLI override: UNIFI_TAG=${UNIFI_TAG}"
  else
    detail "UniFi will upgrade to tag: latest (default)"
  fi
  if [[ "${MONGO_TAG_CLI_SET}" -eq 1 ]]; then
    detail "CLI override: MONGO_TAG=${MONGO_TAG}"
    validate_mongo_tag_upgrade "${old_mongo_tag}" "${MONGO_TAG}"
  else
    detail "Mongo tag will remain: ${old_mongo_tag}"
  fi

  info "Pausing UniFi app container for a consistent MongoDB baseline snapshot..."
  docker_compose stop -t 60 unifi 2>/dev/null || true

  capture_mongo_baseline

  graceful_stop_for_backup
  create_backup_archive

  write_env_file "upgrade"
  write_compose_files

  if docker_compose_quiet ps -a --services 2>/dev/null | grep -q .; then
    info "Removing stopped container definitions (data volumes preserved on disk)..."
    docker_compose down --timeout 10
  fi
  ok "Containers stopped. mongo-data/ and config/ were NOT deleted."

  check_port_conflicts

  info "Pulling updated container images..."
  docker_compose pull

  info "Starting upgraded containers..."
  docker_compose up -d

  wait_for_mongo_healthy

  if ! scan_mongo_logs_for_errors; then
    err "MongoDB storage/upgrade errors detected in container logs."
    if rollback_from_backup; then
      die "Upgrade aborted and rolled back due to MongoDB log errors. Backup: ${BACKUP_ARCHIVE}"
    else
      die "Upgrade failed AND rollback failed. Restore manually from: ${BACKUP_ARCHIVE}"
    fi
  fi

  if ! verify_mongo_baseline; then
    err "Post-upgrade verification failed — initiating rollback."
    if rollback_from_backup; then
      die "Upgrade aborted and rolled back. Your previous install should be running again. Backup: ${BACKUP_ARCHIVE}"
    else
      die "Upgrade failed AND rollback failed. Restore manually from: ${BACKUP_ARCHIVE}"
    fi
  fi

  verify_config_preserved
  wait_for_unifi_web || warn "Web UI slow to start; MongoDB data verified OK."

  ROLLBACK_ENABLED=0
  print_summary "upgrade"
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
print_summary() {
  local mode="$1"
  local host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  host_ip="${host_ip:-<this-machine-ip>}"

  echo ""
  echo "================================================================"
  if [[ "${mode}" == "upgrade" ]]; then
    echo " Upgrade complete — data verification passed"
  else
    echo " Fresh installation complete"
  fi
  echo "================================================================"
  echo " Web UI:        https://${host_ip}:8443"
  echo " Install dir:   ${INSTALL_DIR}"
  echo " Credentials:   ${INSTALL_DIR}/.env  (chmod 600 — back up securely)"
  echo " Logs:          cd ${INSTALL_DIR} && sudo docker compose logs -f"
  echo " Script log:    ${LOG_FILE}"
  if [[ "${mode}" == "upgrade" && -n "${BACKUP_ARCHIVE}" ]]; then
    echo " Backup:        ${BACKUP_ARCHIVE}"
    echo " Baseline:      ${BASELINE_FILE}"
  fi
  if [[ "${mode}" == "fresh" && "${MIGRATION_RESTORE_OK}" -eq 1 ]]; then
    echo "----------------------------------------------------------------"
    echo " Automated migration complete"
    echo " Backup used:   ${MIGRATION_UNF}"
    echo " Web UI:        https://${host_ip}:8443"
    echo " Verify devices reconnect; adopt if Inform Host was set."
    echo "----------------------------------------------------------------"
  elif [[ "${mode}" == "fresh" && "${MIGRATE_FROM_DEB}" -eq 1 ]]; then
    echo "----------------------------------------------------------------"
    echo " Docker installed — finish migration manually if restore did not run:"
    echo "   Backup file: ${MIGRATION_UNF:-<see migration-backup/ >}"
    echo "   Web UI: https://${host_ip}:8443 -> Restore from backup"
    echo "   Set Inform Host to ${host_ip} with Override enabled"
    echo "----------------------------------------------------------------"
  elif [[ "${mode}" == "fresh" && "${LEGACY_REASON}" == "native_deb_migrate" ]]; then
    echo "----------------------------------------------------------------"
    echo " Native (.deb) -> Docker migration — next steps:"
    echo "   1. Open the web UI above and complete the setup wizard"
    echo "   2. Choose Restore from backup and upload your .unf file"
    echo "   3. Settings -> System -> Advanced -> Inform Host = ${host_ip}"
    echo "      Enable Override Inform Host"
    echo "   4. Optional after devices reconnect: sudo systemctl disable --now unifi"
    echo "----------------------------------------------------------------"
  elif [[ "${mode}" == "fresh" ]]; then
    echo "----------------------------------------------------------------"
    echo " Migrating from another controller (manual restore):"
    echo "   1. Old controller: Settings -> System -> Download backup (.unf)"
    echo "   2. New wizard here: Restore from backup"
    echo "   3. Set Inform Host to ${host_ip} with Override enabled"
    echo "----------------------------------------------------------------"
  fi
  if [[ "${EUID}" -ne 0 ]]; then
    echo " NOTE: Log out and back in to run 'docker' without sudo."
  fi
  echo "================================================================"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
detect_installation

if [[ "${INSTALL_MODE}" == "blocked" ]]; then
  report_blocked_legacy
  if [[ "${LEGACY_REASON}" == "native_deb" ]]; then
    err "Native .deb UniFi is installed — this run did not include --migrate-from-deb."
    err "Re-run with credentials, for example:"
    err "  UNIFI_CTRL_USER=admin UNIFI_CTRL_PASS='your-password' ./install-unifi-docker.sh --migrate-from-deb -y"
  fi
  abort_data_loss "Resolve the legacy state above, then re-run this script."
fi

if [[ "${MIGRATE_FROM_DEB}" -eq 1 || "${FORCE_FRESH}" -eq 1 ]]; then
  if [[ "${INSTALL_MODE}" == "upgrade" ]]; then
    abort_data_loss "--fresh/--migrate-from-deb was specified but an existing Docker install was detected at ${INSTALL_DIR}."
  fi
  INSTALL_MODE="fresh"
fi

check_system_resources
compute_memory_limits

confirm_proceed
install_docker

case "${INSTALL_MODE}" in
  fresh) run_fresh_install ;;
  upgrade) run_upgrade ;;
  *) die "Unknown install mode: ${INSTALL_MODE}" ;;
esac
