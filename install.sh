#!/usr/bin/env bash
# AI Node post-install bootstrapper for Ubuntu Server 22.04 / 24.04 / 26.04
set -euo pipefail

SCRIPT_VERSION="0.1.0"
INSTALL_DIR="/opt/ai-node"
AGENT_PATH="${INSTALL_DIR}/agent.py"
VENV_DIR="${INSTALL_DIR}/venv"
SERVICE_NAME="ai-node.agent.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
DEFAULT_AGENT_URL="https://raw.githubusercontent.com/thryveapex/ai-agent/main/agent.py"

DRY_RUN=0

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_RESET='\033[0m'
  C_INFO='\033[0;36m'
  C_OK='\033[0;32m'
  C_WARN='\033[0;33m'
  C_ERR='\033[0;31m'
else
  C_RESET=''
  C_INFO=''
  C_OK=''
  C_WARN=''
  C_ERR=''
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()  { printf '%b[%s] INFO %s%b\n'  "${C_INFO}" "$(_ts)" "$*" "${C_RESET}"; }
log_ok()    { printf '%b[%s] OK   %s%b\n'  "${C_OK}"   "$(_ts)" "$*" "${C_RESET}"; }
log_warn()  { printf '%b[%s] WARN %s%b\n'  "${C_WARN}" "$(_ts)" "$*" "${C_RESET}"; }
log_error() { printf '%b[%s] ERR  %s%b\n'  "${C_ERR}"  "$(_ts)" "$*" "${C_RESET}" >&2; }

die() {
  log_error "$@"
  exit 1
}

run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] $*"
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Bootstrap a private AI node on Ubuntu Server 22.04, 24.04, or 26.04 after a normal
Ubuntu install. Installs Docker, Avahi, the agent, and a systemd unit.

Options:
  -h, --help      Show this help and exit
  -n, --dry-run   Print actions without changing the system
  -V, --version   Print script version and exit

Environment:
  RUN_AS      User that owns the agent process and is added to the docker group
              (default: SUDO_USER of the installing account)
  AGENT_URL   URL to download agent.py
              (default: ${DEFAULT_AGENT_URL})

Example:
  curl -fsSL https://ourapp.ai/install.sh | bash
  RUN_AS=ai-admin sudo -E bash install.sh
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -n|--dry-run)
        DRY_RUN=1
        shift
        ;;
      -V|--version)
        printf '%s\n' "${SCRIPT_VERSION}"
        exit 0
        ;;
      *)
        die "Unknown option: $1 (try --help)"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

require_linux_ubuntu() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log_warn "Dry-run on non-Linux ($(uname -s)); continuing with planned steps only"
      return 0
    fi
    die "This installer only supports Linux (found: $(uname -s))"
  fi

  if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect distribution (/etc/os-release missing)"
  fi

  # shellcheck source=/dev/null
  . /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    die "Unsupported distribution: ${PRETTY_NAME:-unknown}. Only Ubuntu is supported."
  fi

  case "${VERSION_ID:-}" in
    22.04|24.04|26.04)
      log_ok "Detected Ubuntu ${VERSION_ID}"
      ;;
    *)
      die "Unsupported Ubuntu version: ${VERSION_ID:-unknown}. Supported: 22.04, 24.04, 26.04"
      ;;
  esac
}

require_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_warn "Not root; continuing dry-run without privilege escalation"
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    log_info "Re-executing with sudo..."
    exec sudo --preserve-env=RUN_AS,AGENT_URL,NO_COLOR env bash "$0" "$@"
  fi

  die "Root privileges required. Re-run as root or with sudo."
}

resolve_run_as() {
  local candidate="${RUN_AS:-${SUDO_USER:-}}"

  if [[ -z "${candidate}" || "${candidate}" == "root" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      candidate="${USER:-dry-run-user}"
      if [[ "${candidate}" == "root" ]]; then
        candidate="dry-run-user"
      fi
      log_warn "Dry-run: using placeholder RUN_AS='${candidate}'"
    else
      die "Cannot determine non-root RUN_AS user. Set RUN_AS=<username> and re-run."
    fi
  fi

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    if ! id "${candidate}" >/dev/null 2>&1; then
      die "RUN_AS user '${candidate}' does not exist"
    fi
  fi

  RUN_AS="${candidate}"
  log_ok "Agent will run as user '${RUN_AS}'"
}

# ---------------------------------------------------------------------------
# Install steps
# ---------------------------------------------------------------------------

install_packages() {
  local packages=(
    curl
    git
    docker.io
    docker-compose-v2
    avahi-daemon
    python3
    python3-pip
    python3-venv
  )

  log_info "Updating apt package index..."
  run apt-get update -y

  log_info "Installing packages: ${packages[*]}"
  # DEBIAN_FRONTEND avoids interactive prompts on fresh servers
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  log_ok "Packages installed"
}

enable_services() {
  log_info "Enabling and starting docker..."
  run systemctl enable --now docker

  log_info "Enabling and starting avahi-daemon..."
  run systemctl enable --now avahi-daemon

  log_ok "docker and avahi-daemon are enabled"
}

prepare_install_dir() {
  log_info "Ensuring ${INSTALL_DIR} exists..."
  run mkdir -p "${INSTALL_DIR}"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    chown "${RUN_AS}:${RUN_AS}" "${INSTALL_DIR}"
  else
    log_info "[dry-run] chown ${RUN_AS}:${RUN_AS} ${INSTALL_DIR}"
  fi
}

download_agent() {
  local url="${AGENT_URL:-${DEFAULT_AGENT_URL}}"
  local tmp

  log_info "Downloading agent from ${url}..."
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] curl -fsSL ${url} -o ${AGENT_PATH}"
    return 0
  fi

  tmp="$(mktemp)"
  if ! curl -fsSL "${url}" -o "${tmp}"; then
    rm -f "${tmp}"
    die "Failed to download agent from ${url}"
  fi

  if [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}"
    die "Downloaded agent file is empty"
  fi

  mv "${tmp}" "${AGENT_PATH}"
  chown "${RUN_AS}:${RUN_AS}" "${AGENT_PATH}"
  chmod 644 "${AGENT_PATH}"
  log_ok "Agent installed at ${AGENT_PATH}"
}

setup_venv() {
  log_info "Setting up Python venv at ${VENV_DIR}..."

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] python3 -m venv ${VENV_DIR}"
    log_info "[dry-run] ${VENV_DIR}/bin/pip install -U pip requests websocket-client"
    return 0
  fi

  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    python3 -m venv "${VENV_DIR}"
  else
    log_info "Venv already exists; reusing"
  fi

  "${VENV_DIR}/bin/pip" install -U pip requests websocket-client
  chown -R "${RUN_AS}:${RUN_AS}" "${VENV_DIR}"
  log_ok "Python dependencies installed (requests, websocket-client)"
}

add_docker_group() {
  log_info "Adding '${RUN_AS}' to the docker group..."
  run usermod -aG docker "${RUN_AS}"
  log_ok "User '${RUN_AS}' is in the docker group (re-login required for new shells)"
}

write_systemd_unit() {
  log_info "Writing ${SERVICE_PATH}..."

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] write systemd unit for ${SERVICE_NAME}"
    log_info "[dry-run] systemctl daemon-reload"
    log_info "[dry-run] systemctl enable --now ${SERVICE_NAME}"
    return 0
  fi

  cat >"${SERVICE_PATH}" <<EOF
[Unit]
Description=AI Node Agent
Documentation=https://github.com/thryveapex/ai-agent
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
User=${RUN_AS}
Group=${RUN_AS}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${VENV_DIR}/bin/python ${AGENT_PATH}
Restart=always
RestartSec=5
# Ensure PATH includes common locations for nvidia-smi when present
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
  # Restart so re-runs pick up unit / agent / venv changes
  systemctl restart "${SERVICE_NAME}"
  log_ok "Service ${SERVICE_NAME} enabled and started"
}

lan_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  fi
  if [[ -z "${ip}" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  printf '%s\n' "${ip:-unknown}"
}

print_summary() {
  local host
  local ip
  host="$(hostname 2>/dev/null || echo unknown)"
  ip="$(lan_ip)"

  cat <<EOF

============================================================
  AI Node install complete (script v${SCRIPT_VERSION})
============================================================
  Hostname:     ${host}
  LAN IP:       ${ip}
  Install dir:  ${INSTALL_DIR}
  Agent:        ${AGENT_PATH}
  Service:      ${SERVICE_NAME}
  Run as:       ${RUN_AS}

  Check status:
    systemctl status ${SERVICE_NAME}
    journalctl -u ${SERVICE_NAME} -f

  Next steps:
    1. Re-login (or newgrp docker) so docker group membership applies.
    2. Ensure NVIDIA drivers are installed so nvidia-smi works (GPU heartbeats).
    3. Confirm CONTROL_PLANE_URL / MACHINE_ID / AGENT_TOKEN in
       ${AGENT_PATH} match your control plane (hardcoded in agent.py today).
    4. Ensure the control plane and local vLLM endpoint are reachable.
============================================================
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"

  log_info "AI Node installer v${SCRIPT_VERSION}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_warn "Dry-run mode: no system changes will be made"
  fi

  # Preserve original args for sudo re-exec
  require_root "$@"
  require_linux_ubuntu
  resolve_run_as

  install_packages
  enable_services
  prepare_install_dir
  download_agent
  setup_venv
  add_docker_group
  write_systemd_unit

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_ok "Dry-run finished; no changes applied"
  else
    print_summary
  fi
}

main "$@"
