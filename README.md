# AI Node Installer

Post-install bootstrapper for private AI nodes. Install Ubuntu Server 22.04, 24.04, or 26.04 with the normal Ubuntu installer, then run this script to set up Docker, Avahi, the agent, and a systemd service.

This replaces the previous custom autoinstall ISO flow. It does **not** build an ISO or configure cloud-init.

## Prerequisites

- Fresh **Ubuntu Server 22.04, 24.04, or 26.04** install
- Root or sudo access
- Network access (to apt mirrors and GitHub)
- SSH optional (configure during Ubuntu install if you want remote access)
- **GPU nodes:** an NVIDIA GPU. The installer detects it and installs drivers automatically (a reboot is usually required once).

## Install

```bash
curl -fsSL https://ourapp.ai/install.sh | bash
```

Or from a local checkout:

```bash
sudo bash install.sh
```

### Optional environment variables

| Variable | Description |
|----------|-------------|
| `RUN_AS` | User that runs the agent and is added to the `docker` group. Defaults to `$SUDO_USER`. |
| `AGENT_URL` | URL for `agent.py`. Defaults to the public raw GitHub URL for `thryveapex/ai-agent`. |
| `SKIP_NVIDIA` | Set to `1` to skip NVIDIA driver installation. |
| `NO_REBOOT` | Set to `1` to skip the automatic reboot after a new driver install. |

Examples:

```bash
RUN_AS=ai-admin sudo -E bash install.sh
AGENT_URL=https://example.com/agent.py sudo -E bash install.sh
SKIP_NVIDIA=1 sudo -E bash install.sh
NO_REBOOT=1 sudo -E bash install.sh
```

### Flags

```bash
bash install.sh --help
bash install.sh --version
bash install.sh --dry-run   # print planned actions; no changes
```

## What it does

1. Verifies Linux + Ubuntu 22.04/24.04/26.04
2. Installs: `curl`, `git`, `docker.io`, `docker-compose-v2`, `avahi-daemon`, `python3`, `python3-pip`, `python3-venv`
3. Detects an NVIDIA GPU and installs the recommended NVIDIA drivers (unless `SKIP_NVIDIA=1`)
4. Enables and starts `docker` and `avahi-daemon`
5. Creates `/opt/ai-node` and downloads `agent.py`
6. Creates `/opt/ai-node/venv` and installs `requests` + `websocket-client`
7. Adds the install user to the `docker` group
8. Installs and starts `ai-node.agent.service`
9. Reboots automatically if drivers were newly installed and `nvidia-smi` is not active yet (unless `NO_REBOOT=1`)

After reboot, the agent service starts on its own and can send GPU heartbeats once `nvidia-smi` works.

## Re-run

The script is idempotent. Re-running is safe: packages stay installed, the agent file is refreshed, the venv deps are upgraded, and the systemd unit is rewritten and restarted.

## Uninstall (manual)

There is no `uninstall.sh` yet. To tear down:

```bash
sudo systemctl disable --now ai-node.agent.service
sudo rm -f /etc/systemd/system/ai-node.agent.service
sudo systemctl daemon-reload
sudo rm -rf /opt/ai-node
# Optional: leave docker / avahi / python packages installed
```

## Agent configuration note

`agent.py` currently hardcodes `CONTROL_PLANE_URL`, `MACHINE_ID`, `AGENT_TOKEN`, and `VLLM_CHAT_COMPLETIONS_URL`. After install, edit `/opt/ai-node/agent.py` if those values must match your environment, then:

```bash
sudo systemctl restart ai-node.agent.service
```

## Development checks

```bash
make check    # shellcheck if available
make dry-run  # non-destructive install.sh --dry-run
```

## Troubleshooting

| Symptom | What to try |
|--------|-------------|
| Unsupported distro / version | Use Ubuntu Server 22.04, 24.04, or 26.04 only |
| Agent download fails | Check network / DNS; override with `AGENT_URL` if needed |
| `ModuleNotFoundError: requests` or `websocket` | Re-run the installer so the venv is created and deps are installed |
| Service crash loop mentioning `nvidia-smi` | Re-run the installer (it installs NVIDIA drivers), reboot if needed, then confirm `nvidia-smi` works |
| Installer rebooted the machine | Expected after a first-time NVIDIA driver install; after boot check `nvidia-smi` and `systemctl status ai-node.agent.service` |
| Want to skip drivers / reboot | `SKIP_NVIDIA=1` or `NO_REBOOT=1` |
| Control plane / heartbeat errors | Verify URL and token in `/opt/ai-node/agent.py` and that the control plane is reachable |
| `docker: permission denied` | Log out and back in (or `newgrp docker`) after install |
| Check logs | `journalctl -u ai-node.agent.service -f` |

## Security note

Older autoinstall configs may have embedded a long-lived GitHub PAT. This script never hardcodes tokens. Rotate any PAT that was previously committed.
