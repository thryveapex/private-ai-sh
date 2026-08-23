# AI Node Installer

Post-install bootstrapper for private AI nodes. Install Ubuntu Server 22.04, 24.04, or 26.04 with the normal Ubuntu installer, then run this script to set up Docker, Avahi, the agent, and a systemd service.

This replaces the previous custom autoinstall ISO flow. It does **not** build an ISO or configure cloud-init.

## Prerequisites

- Fresh **Ubuntu Server 22.04, 24.04, or 26.04** install
- Root or sudo access
- Network access (to apt mirrors and GitHub)
- SSH optional (configure during Ubuntu install if you want remote access)
- **GPU nodes:** NVIDIA drivers so `nvidia-smi` works (the agent calls it for heartbeats; this script does not install drivers)

## Install

```bash
curl -fsSL https://ourapp.ai/install.sh | bash
```

Or from a local checkout:

```bash
sudo bash install.sh
```

### Optional environment variables

| Variable   | Description |
|-----------|-------------|
| `RUN_AS`  | User that runs the agent and is added to the `docker` group. Defaults to `$SUDO_USER`. |
| `AGENT_URL` | URL for `agent.py`. Defaults to the public raw GitHub URL for `thryveapex/ai-agent`. |

Examples:

```bash
RUN_AS=ai-admin sudo -E bash install.sh
AGENT_URL=https://example.com/agent.py sudo -E bash install.sh
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
3. Enables and starts `docker` and `avahi-daemon`
4. Creates `/opt/ai-node` and downloads `agent.py`
5. Creates `/opt/ai-node/venv` and installs `requests` + `websocket-client`
6. Adds the install user to the `docker` group
7. Installs and starts `ai-node.agent.service`

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
| Service crash loop mentioning `nvidia-smi` | Install NVIDIA drivers; confirm `nvidia-smi` works for the `RUN_AS` user |
| Control plane / heartbeat errors | Verify URL and token in `/opt/ai-node/agent.py` and that the control plane is reachable |
| `docker: permission denied` | Log out and back in (or `newgrp docker`) after install |
| Check logs | `journalctl -u ai-node.agent.service -f` |

## Security note

Older autoinstall configs may have embedded a long-lived GitHub PAT. This script never hardcodes tokens. Rotate any PAT that was previously committed.
# private-ai-sh
