# Route-Monitor
Event‑driven route guard that watches for a specific destination and enforces a blackhole entry. All output goes to a timestamped log; no stdout chatter.

## Architecture

- **Monitoring**: Uses `ip monitor route` (netlink) for millisecond reaction.
- **Enforcement**: Adds `blackhole <IP>` instead of deleting routes.
- **Safety**: Single-instance via lockfile/PID; rotates logs; systemd-managed.
- **Config**: Environment or `/etc/route-monitor/config.conf`.

## Requirements

- Linux with `iproute2` (kernel ≥ 3.2 recommended)
- Root privileges (for `ip` commands)
- Bash 4+

## Quick start

1. Edit `/etc/route-monitor/config.conf` with your `TARGET_IP`.
2. Run `sudo ./install.sh` (or follow manual install steps).
3. Check `sudo systemctl status route-monitor.service`.

See `route_monitor.sh` for CLI overrides (`MODE`, `LOG_FILE`, etc.).

## Security considerations

- Runs as root; systemd hardening restricts capabilities.
- Logs are readable by root only (0640).
- No secrets in repo; redact internal IPs before sharing.

## Troubleshooting

```bash
sudo journalctl -u route-monitor.service -xe
sudo ip monitor route  # verify event stream manually
