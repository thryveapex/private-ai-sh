#!/usr/bin/env bash
# AI Node post-install bootstrapper for Ubuntu Server 22.04 / 24.04 / 26.04
set -euo pipefail

SCRIPT_VERSION="0.4.0"
INSTALL_DIR="/opt/ai-node"
AGENT_PATH="${INSTALL_DIR}/agent.py"
CREDENTIALS_PATH="${INSTALL_DIR}/credentials.json"
VENV_DIR="${INSTALL_DIR}/venv"
SERVICE_NAME="ai-node.agent.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
DEFAULT_AGENT_URL="https://raw.githubusercontent.com/thryveapex/ai-agent/main/agent.py"
DEFAULT_CONTROL_PLANE_URL="http://192.168.1.3:3000"

DRY_RUN=0
REBOOT_REQUIRED=0
ENROLLMENT_KEY="${ENROLLMENT_KEY:-}"
CONTROL_PLANE_URL="${CONTROL_PLANE_URL:-${DEFAULT_CONTROL_PLANE_URL}}"
ENROLLED_MACHINE_ID=""
ENROLLED_USER_ID=""

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
  -h, --help                      Show this help and exit
  -n, --dry-run                   Print actions without changing the system
  -V, --version                   Print script version and exit
  --enrollment-key <key>          One-time enrollment key from the dashboard
  --control-plane-url <url>       Control Plane base URL
                                  (default: ${DEFAULT_CONTROL_PLANE_URL})

Environment:
  RUN_AS              User that owns the agent process and is added to the docker group
                      (default: SUDO_USER of the installing account)
  AGENT_URL           URL to download agent.py
                      (default: ${DEFAULT_AGENT_URL})
  ENROLLMENT_KEY      Same as --enrollment-key
  CONTROL_PLANE_URL   Same as --control-plane-url
  SKIP_NVIDIA         Set to 1 to skip NVIDIA driver and container toolkit installation
  NO_REBOOT           Set to 1 to skip automatic reboot after new driver install

Example:
  curl -fsSL https://ourapp.ai/install.sh | bash
  RUN_AS=ai-admin sudo -E bash install.sh --enrollment-key ABCDEFGHJK
  SKIP_NVIDIA=1 sudo -E bash install.sh --enrollment-key ABCDEFGHJK
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
      --enrollment-key)
        [[ $# -ge 2 ]] || die "--enrollment-key requires a value"
        ENROLLMENT_KEY="$2"
        shift 2
        ;;
      --control-plane-url)
        [[ $# -ge 2 ]] || die "--control-plane-url requires a value"
        CONTROL_PLANE_URL="$2"
        shift 2
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
    exec sudo --preserve-env=RUN_AS,AGENT_URL,NO_COLOR,SKIP_NVIDIA,NO_REBOOT,ENROLLMENT_KEY,CONTROL_PLANE_URL env bash "$0" "$@"
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

has_nvidia_gpu() {
  if command -v lspci >/dev/null 2>&1; then
    lspci 2>/dev/null | grep -qi 'nvidia'
    return $?
  fi
  return 1
}

nvidia_smi_ok() {
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1
}

install_nvidia_drivers() {
  if [[ "${SKIP_NVIDIA:-0}" == "1" ]]; then
    log_warn "SKIP_NVIDIA=1; skipping NVIDIA driver installation"
    return 0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] detect NVIDIA GPU and install drivers via ubuntu-drivers if needed"
    return 0
  fi

  # lspci needs pciutils; install lightly before detection
  if ! command -v lspci >/dev/null 2>&1; then
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y pciutils
  fi

  if ! has_nvidia_gpu; then
    log_warn "No NVIDIA GPU detected (lspci). Agent heartbeats need nvidia-smi and will fail without a GPU/drivers."
    return 0
  fi

  log_ok "NVIDIA GPU detected"

  if nvidia_smi_ok; then
    log_ok "nvidia-smi already works; skipping driver install"
    return 0
  fi

  log_info "Installing NVIDIA drivers (required for agent heartbeats)..."
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-drivers-common

  # Prefer the Ubuntu recommended driver; fall back to autoinstall.
  local recommended=""
  recommended="$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/{print $3; exit}' || true)"
  if [[ -n "${recommended}" && "${recommended}" == nvidia-driver-* ]]; then
    log_info "Installing recommended package: ${recommended}"
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${recommended}"
  else
    log_info "Running ubuntu-drivers autoinstall..."
    run env DEBIAN_FRONTEND=noninteractive ubuntu-drivers autoinstall
  fi

  if nvidia_smi_ok; then
    log_ok "NVIDIA drivers are active (nvidia-smi OK)"
    return 0
  fi

  REBOOT_REQUIRED=1
  log_warn "NVIDIA drivers installed but nvidia-smi is not active yet (kernel module needs a reboot)"
}

docker_nvidia_runtime_ok() {
  # True when Docker can see the nvidia runtime (toolkit configured).
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi
  docker info 2>/dev/null | grep -qi 'Runtimes:.*nvidia'
}

install_nvidia_container_toolkit() {
  # Required for: docker run --gpus all ...
  # Host nvidia-smi alone is not enough for GPU containers (vLLM).
  if [[ "${SKIP_NVIDIA:-0}" == "1" ]]; then
    log_warn "SKIP_NVIDIA=1; skipping NVIDIA Container Toolkit"
    return 0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] install nvidia-container-toolkit and configure Docker GPU runtime"
    return 0
  fi

  if ! command -v lspci >/dev/null 2>&1; then
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y pciutils
  fi

  if ! has_nvidia_gpu; then
    log_warn "No NVIDIA GPU detected; skipping NVIDIA Container Toolkit"
    return 0
  fi

  if docker_nvidia_runtime_ok && dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
    log_ok "NVIDIA Container Toolkit already configured for Docker"
    return 0
  fi

  log_info "Installing NVIDIA Container Toolkit (required for docker --gpus)..."

  run env DEBIAN_FRONTEND=noninteractive apt-get install -y curl gnupg ca-certificates

  local keyring="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
  local list_file="/etc/apt/sources.list.d/nvidia-container-toolkit.list"

  if [[ ! -f "${keyring}" ]]; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor -o "${keyring}"
  fi

  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=${keyring}] https://#g" \
    > "${list_file}"

  run apt-get update -y
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit

  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    die "nvidia-ctk not found after installing nvidia-container-toolkit"
  fi

  log_info "Configuring Docker to use the NVIDIA runtime..."
  run nvidia-ctk runtime configure --runtime=docker
  run systemctl restart docker

  # Give docker a moment after restart
  sleep 2

  if docker_nvidia_runtime_ok; then
    log_ok "Docker GPU runtime configured (nvidia)"
  else
    log_warn "NVIDIA toolkit installed; verify with: docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi"
  fi
}

maybe_reboot() {
  if [[ "${REBOOT_REQUIRED}" -ne 1 ]]; then
    return 0
  fi

  if [[ "${NO_REBOOT:-0}" == "1" ]]; then
    log_warn "NO_REBOOT=1; reboot manually, then: sudo systemctl restart ${SERVICE_NAME}"
    return 0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] reboot to load NVIDIA kernel modules"
    return 0
  fi

  log_warn "Rebooting in 10 seconds so NVIDIA drivers load and the agent can send heartbeats..."
  log_warn "Press Ctrl+C to cancel. After reboot the agent service starts automatically."
  sleep 10
  systemctl reboot
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
    log_info "[dry-run] ${VENV_DIR}/bin/pip install -U pip requests websocket-client psutil"
    return 0
  fi

  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    python3 -m venv "${VENV_DIR}"
  else
    log_info "Venv already exists; reusing"
  fi

  "${VENV_DIR}/bin/pip" install -U pip requests websocket-client psutil
  chown -R "${RUN_AS}:${RUN_AS}" "${VENV_DIR}"
  log_ok "Python dependencies installed (requests, websocket-client, psutil)"
}

add_docker_group() {
  log_info "Adding '${RUN_AS}' to the docker group..."
  run usermod -aG docker "${RUN_AS}"
  log_ok "User '${RUN_AS}' is in the docker group (re-login required for new shells)"
}

resolve_enrollment_key() {
  if [[ -n "${ENROLLMENT_KEY}" ]]; then
    return 0
  fi

  if [[ -t 0 ]]; then
    printf 'Enter enrollment key: '
    read -r ENROLLMENT_KEY
  fi

  if [[ -z "${ENROLLMENT_KEY}" ]]; then
    die "Enrollment key is required. Pass --enrollment-key <key> or set ENROLLMENT_KEY."
  fi
}

detect_gpu_name() {
  local gpu=""
  if command -v nvidia-smi >/dev/null 2>&1; then
    gpu="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
  fi
  if [[ -z "${gpu}" ]]; then
    gpu="unknown"
  fi
  printf '%s\n' "${gpu}"
}

enroll_machine() {
  local hostname
  local gpu
  local payload_file
  local response_file
  local http_code
  local body
  local agent_token

  resolve_enrollment_key

  hostname="$(hostname 2>/dev/null || echo unknown)"
  gpu="$(detect_gpu_name)"

  log_info "Enrolling machine with Control Plane at ${CONTROL_PLANE_URL}..."

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[dry-run] POST ${CONTROL_PLANE_URL}/machines/enroll"
    log_info "[dry-run] write ${CREDENTIALS_PATH}"
    ENROLLED_MACHINE_ID="dry-run-machine-id"
    ENROLLED_USER_ID="dry-run-user-id"
    return 0
  fi

  payload_file="$(mktemp)"
  response_file="$(mktemp)"

  ENROLLMENT_KEY="${ENROLLMENT_KEY}" \
  HOSTNAME_VALUE="${hostname}" \
  GPU_VALUE="${gpu}" \
  python3 - <<'PY' >"${payload_file}"
import json
import os

print(json.dumps({
    "enrollment_key": os.environ["ENROLLMENT_KEY"],
    "hostname": os.environ["HOSTNAME_VALUE"],
    "hardware": {"gpu": os.environ["GPU_VALUE"]},
}))
PY

  http_code="$(
    curl -sS -o "${response_file}" -w '%{http_code}' \
      -X POST \
      -H 'Content-Type: application/json' \
      -d @"${payload_file}" \
      "${CONTROL_PLANE_URL}/machines/enroll" || true
  )"
  body="$(cat "${response_file}")"
  rm -f "${payload_file}"

  if [[ "${http_code}" != "200" ]]; then
    rm -f "${response_file}"
    die "Machine enrollment failed (HTTP ${http_code}): ${body}"
  fi

  ENROLLED_MACHINE_ID="$(python3 - <<PY
import json
with open("${response_file}", encoding="utf-8") as handle:
    print(json.load(handle)["machine_id"])
PY
)"
  agent_token="$(python3 - <<PY
import json
with open("${response_file}", encoding="utf-8") as handle:
    print(json.load(handle)["agent_token"])
PY
)"
  ENROLLED_USER_ID="$(python3 - <<PY
import json
with open("${response_file}", encoding="utf-8") as handle:
    print(json.load(handle).get("user_id", ""))
PY
)"
  rm -f "${response_file}"

  CONTROL_PLANE_URL="${CONTROL_PLANE_URL}" \
  MACHINE_ID_VALUE="${ENROLLED_MACHINE_ID}" \
  AGENT_TOKEN_VALUE="${agent_token}" \
  CREDENTIALS_PATH_VALUE="${CREDENTIALS_PATH}" \
  python3 - <<'PY'
import json
import os

credentials = {
    "control_plane_url": os.environ["CONTROL_PLANE_URL"],
    "machine_id": os.environ["MACHINE_ID_VALUE"],
    "agent_token": os.environ["AGENT_TOKEN_VALUE"],
}
with open(os.environ["CREDENTIALS_PATH_VALUE"], "w", encoding="utf-8") as handle:
    json.dump(credentials, handle, indent=2)
    handle.write("\n")
PY

  chown "${RUN_AS}:${RUN_AS}" "${CREDENTIALS_PATH}"
  chmod 600 "${CREDENTIALS_PATH}"
  log_ok "Machine enrolled (${ENROLLED_MACHINE_ID}); credentials written to ${CREDENTIALS_PATH}"
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
  Credentials:  ${CREDENTIALS_PATH}
  Service:      ${SERVICE_NAME}
  Run as:       ${RUN_AS}
  Control Plane:${CONTROL_PLANE_URL}
  Machine ID:   ${ENROLLED_MACHINE_ID:-unknown}
  User ID:      ${ENROLLED_USER_ID:-unknown}

  Check status:
    systemctl status ${SERVICE_NAME}
    journalctl -u ${SERVICE_NAME} -f

  Next steps:
    1. Re-login (or newgrp docker) so docker group membership applies.
    2. Confirm the machine appears in your dashboard for this user.
    3. Ensure the control plane and local vLLM endpoint are reachable.
    4. If NVIDIA drivers were just installed, reboot if the script did not
       (or set NO_REBOOT=1 and reboot yourself), then verify:
         nvidia-smi
         systemctl status ${SERVICE_NAME}
EOF

  if [[ "${REBOOT_REQUIRED}" -eq 1 && "${NO_REBOOT:-0}" != "1" ]]; then
    cat <<EOF
  NOTE: A reboot is required next so nvidia-smi works and heartbeats succeed.
============================================================
EOF
  else
    cat <<EOF
============================================================
EOF
  fi
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
  install_nvidia_drivers
  enable_services
  install_nvidia_container_toolkit
  prepare_install_dir
  download_agent
  setup_venv
  add_docker_group
  enroll_machine
  write_systemd_unit

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_ok "Dry-run finished; no changes applied"
  else
    print_summary
    maybe_reboot
  fi
}

main "$@"
