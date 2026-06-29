#!/usr/bin/env bash
#
# install-unifi-os-server.sh
#
# Installs Ubiquiti's official UniFi OS Server on Ubuntu/Debian via the
# supported Podman-based installer (NOT the legacy linuxserver Docker stack).
#
# UniFi OS Server = unified UniFi OS experience (Organizations, Site Manager, etc.)
# Legacy Network Application = linuxserver/unifi-network-application + external MongoDB
#
# Usage:
#   ./install-unifi-os-server.sh [options]
#
# Options:
#   --migrate-from-deb       Stop native unifi.service and locate a .unf backup first
#   --remove-legacy-docker   Stop Docker Compose stack at --legacy-dir (default: ~/unifi)
#   --legacy-dir PATH        Legacy linuxserver install directory (default: ~/unifi)
#   --installer-url URL      Skip API lookup; use this Ubiquiti installer URL
#   --installer-path PATH    Use a local installer binary instead of downloading
#   -y, --yes                Non-interactive (auto-confirm installer prompt)
#   -h, --help               Show help
#
# After install, open: https://<host>:11443
# Restore migration backup via Settings → System → Restore in the UOS wizard.
#
# License: MIT

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0.0"
FIRMWARE_API="https://fw-update.ubnt.com/api/firmware-latest"

MIGRATE_FROM_DEB=0
REMOVE_LEGACY_DOCKER=0
LEGACY_DIR="${HOME}/unifi"
INSTALLER_URL=""
INSTALLER_PATH=""
ASSUME_YES=0

LOG_FILE="/tmp/unifi-os-install-$(date +%Y%m%d-%H%M%S).log"
DOWNLOAD_DIR="${HOME}/unifi-os-server"
INSTALLER_FILE=""

COLOR_RESET="\033[0m"
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_DIM="\033[2m"

info()    { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET}  $*" | tee -a "${LOG_FILE}"; }
ok()      { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*" | tee -a "${LOG_FILE}"; }
warn()    { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*" | tee -a "${LOG_FILE}"; }
err()     { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" | tee -a "${LOG_FILE}"; }
detail()  { echo -e "${COLOR_DIM}[DETAIL]${COLOR_RESET} $*" | tee -a "${LOG_FILE}"; }
die()     { err "$*"; err "Full log: ${LOG_FILE}"; exit 1; }

usage() {
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --migrate-from-deb) MIGRATE_FROM_DEB=1; shift ;;
    --remove-legacy-docker) REMOVE_LEGACY_DOCKER=1; shift ;;
    --legacy-dir) LEGACY_DIR="$2"; shift 2 ;;
    --installer-url) INSTALLER_URL="$2"; shift 2 ;;
    --installer-path) INSTALLER_PATH="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

port_is_listening() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tuln 2>/dev/null | grep -qE ":${port}[[:space:]]"
    return $?
  fi
  netstat -tuln 2>/dev/null | grep -qE ":${port}[[:space:]]"
}

uos_platform_for_arch() {
  case "$(uname -m)" in
    x86_64) echo "linux-x64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    *) die "Unsupported architecture for UniFi OS Server: $(uname -m)" ;;
  esac
}

parse_firmware_json() {
  local json_file="$1"
  local field="$2"
  python3 - "$json_file" "$field" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
fw = data.get("_embedded", {}).get("firmware", [])
if not fw:
    sys.exit(1)
item = fw[0]
if sys.argv[2] == "version":
    print(item.get("version", "").lstrip("v"))
elif sys.argv[2] == "url":
    print(item["_links"]["data"]["href"])
else:
    sys.exit(1)
PY
}

fetch_latest_installer_url() {
  local platform="$1" api_url version url tmp_json
  platform="$1"
  api_url="${FIRMWARE_API}?filter=eq~~product~~unifi-os-server&filter=eq~~platform~~${platform}&filter=eq~~channel~~release"
  tmp_json="$(mktemp)"
  info "Querying Ubiquiti firmware API for ${platform}..."
  curl -fsSL "${api_url}" -o "${tmp_json}"
  if ! version="$(parse_firmware_json "${tmp_json}" version 2>/dev/null)"; then
    rm -f "${tmp_json}"
    die "Could not parse UniFi OS Server version from Ubiquiti API."
  fi
  url="$(parse_firmware_json "${tmp_json}" url)"
  rm -f "${tmp_json}"
  ok "Latest UniFi OS Server for ${platform}: ${version}"
  detail "Download URL: ${url}"
  INSTALLER_URL="${url}"
}

detect_native_unifi() {
  if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Status}' unifi 2>/dev/null | grep -q "install ok installed"
    return $?
  fi
  [[ -d /usr/lib/unifi && -x /usr/sbin/unifi ]]
}

stop_native_unifi() {
  if systemctl is-active --quiet unifi 2>/dev/null; then
    info "Stopping native unifi.service (still enabled for rollback)..."
    sudo systemctl stop unifi || die "Failed to stop unifi.service"
    ok "Native unifi.service stopped."
  fi
}

find_migration_unf() {
  local dir unf
  for dir in /usr/lib/unifi/data/backup/autobackup /usr/lib/unifi/data/backup "${HOME}/unifi/migration-backup"; do
    [[ -d "${dir}" ]] || continue
    unf="$(find "${dir}" -maxdepth 2 -type f -name '*.unf' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
    if [[ -n "${unf}" ]]; then
      echo "${unf}"
      return 0
    fi
  done
  return 1
}

stop_legacy_docker_stack() {
  [[ -d "${LEGACY_DIR}" ]] || return 0
  [[ -f "${LEGACY_DIR}/docker-compose.yml" ]] || return 0

  warn "Legacy linuxserver Docker stack found at ${LEGACY_DIR}."
  info "Stopping legacy containers (unifi + unifi-db)..."
  (cd "${LEGACY_DIR}" && sudo docker compose down --timeout 30) || warn "docker compose down returned non-zero."

  if [[ "${REMOVE_LEGACY_DOCKER}" -eq 1 ]]; then
    warn "Removing legacy install directory: ${LEGACY_DIR}"
    sudo rm -rf "${LEGACY_DIR}"
    ok "Legacy Docker install removed."
  else
    ok "Legacy Docker stack stopped. Data kept at ${LEGACY_DIR} (pass --remove-legacy-docker to delete)."
  fi
}

check_ports() {
  local port
  info "Checking required ports for UniFi OS Server..."
  for port in 11443 8080 3478 10003; do
    if port_is_listening "${port}"; then
      err "Port ${port} is already in use."
      die "Free port ${port} before installing UniFi OS Server."
    fi
    detail "Port ${port} is available."
  done
  ok "Port check passed."
}

ensure_podman() {
  if command -v podman >/dev/null 2>&1; then
    local ver major minor patch
    ver="$(podman --version | awk '{print $3}')"
    major="${ver%%.*}"; ver="${ver#*.}"; minor="${ver%%.*}"; patch="${ver#*.}"; patch="${patch%%.*}"
    detail "Found podman ${major}.${minor}.${patch}"
    if [[ "${major}" -lt 4 || ( "${major}" -eq 4 && "${minor}" -lt 3 ) ]]; then
      warn "Podman ${ver} is older than 4.3.1; installer may fail."
    else
      ok "Podman version OK."
    fi
    return 0
  fi

  info "Installing podman and uidmap..."
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y podman uidmap slirp4netns curl ca-certificates python3
  ok "Podman installed: $(podman --version)"
}

download_installer() {
  mkdir -p "${DOWNLOAD_DIR}"

  if [[ -n "${INSTALLER_PATH}" ]]; then
    [[ -f "${INSTALLER_PATH}" ]] || die "Installer not found: ${INSTALLER_PATH}"
    INSTALLER_FILE="$(realpath "${INSTALLER_PATH}")"
    ok "Using local installer: ${INSTALLER_FILE}"
    return 0
  fi

  [[ -n "${INSTALLER_URL}" ]] || fetch_latest_installer_url "$(uos_platform_for_arch)"
  INSTALLER_FILE="${DOWNLOAD_DIR}/unifi-os-server-installer"
  info "Downloading UniFi OS Server installer (~800 MB+, this may take a while)..."
  curl -fL --progress-bar -o "${INSTALLER_FILE}" "${INSTALLER_URL}"
  ok "Download complete: $(du -h "${INSTALLER_FILE}" | awk '{print $1}')"
}

run_official_installer() {
  chmod +x "${INSTALLER_FILE}"
  file "${INSTALLER_FILE}" | grep -q 'ELF' || die "Installer is not a valid ELF binary: ${INSTALLER_FILE}"

  info "Running official UniFi OS Server installer..."
  detail "This configures systemd units (uosserver, uosserver-updater) and a Podman container."

  if [[ "${ASSUME_YES}" -eq 1 ]]; then
    printf 'y\n' | sudo "${INSTALLER_FILE}" install
  else
    sudo "${INSTALLER_FILE}" install
  fi
}

verify_uos_services() {
  local i
  info "Verifying UniFi OS Server services..."
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if systemctl is-active --quiet uosserver 2>/dev/null; then
      ok "uosserver.service is active."
      if systemctl is-active --quiet uosserver-updater 2>/dev/null; then
        ok "uosserver-updater.service is active."
      else
        warn "uosserver-updater.service is not active yet."
      fi
      return 0
    fi
    detail "Waiting for uosserver.service (attempt ${i}/10)..."
    sleep 6
  done
  die "uosserver.service did not become active. Check: sudo journalctl -u uosserver -n 100"
}

print_summary() {
  local unf="${1:-}"
  echo ""
  echo "================================================================"
  ok "UniFi OS Server installation complete (script v${SCRIPT_VERSION})."
  echo ""
  echo "  Web UI : https://$(hostname -I 2>/dev/null | awk '{print $1}'):11443"
  echo "           (or https://127.0.0.1:11443 on the host)"
  echo ""
  echo "  Manage : sudo uosserver help"
  echo "  Status : systemctl status uosserver"
  echo ""
  if [[ -n "${unf}" ]]; then
    echo "  Migration backup (.unf):"
    echo "    ${unf}"
    echo "  Restore it in the UOS setup wizard:"
    echo "    Settings → System → Restore (or during first-run setup)"
  fi
  echo ""
  warn "This is NOT the legacy linuxserver Docker stack on port 8443."
  echo "================================================================"
}

# --- main ---
info "UniFi OS Server installer v${SCRIPT_VERSION}"
info "Architecture: $(uname -m) → platform $(uos_platform_for_arch)"

if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
  warn "This script targets Ubuntu/Debian. Continuing anyway."
fi

require_cmd curl
require_cmd sudo
require_cmd python3

if detect_native_unifi && [[ "${MIGRATE_FROM_DEB}" -eq 0 ]]; then
  die "Native unifi .deb package detected. Re-run with --migrate-from-deb to stop it and locate a .unf backup."
fi

MIGRATION_UNF=""
if [[ "${MIGRATE_FROM_DEB}" -eq 1 ]]; then
  info "=== MIGRATION: native .deb → UniFi OS Server ==="
  MIGRATION_UNF="$(find_migration_unf || true)"
  if [[ -n "${MIGRATION_UNF}" ]]; then
    ok "Found .unf backup: ${MIGRATION_UNF}"
  else
    warn "No .unf backup found automatically. Export one from the native UI before continuing."
  fi
  stop_native_unifi
fi

stop_legacy_docker_stack
check_ports
ensure_podman
download_installer

if [[ "${ASSUME_YES}" -eq 0 ]]; then
  echo ""
  read -r -p "Install official UniFi OS Server now? [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
fi

run_official_installer
verify_uos_services
print_summary "${MIGRATION_UNF}"
