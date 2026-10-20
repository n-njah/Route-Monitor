# Route-Monitor

Event-driven route guard that watches for a specific destination and enforces a
blackhole entry. All output goes to a timestamped log; no stdout chatter.
Used for uncertain `route` destinations in your Kernel IP routing table.

---

## Table of contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Configuration](#configuration)
- [Usage](#usage)
- [Security considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Roadmap](#roadmap)
- [License](#license)
- [Disclaimer](#disclaimer)
- [Installation](#installation)

---

## Overview

`route_monitor.sh` monitors the Linux routing table for a configured target IP
and takes enforcement action the moment a matching route appears. It is built
for unattended operation: quiet by default, logged to disk, managed by systemd.

Two enforcement modes are supported:

| Mode        | Action                                              | Use case                                   |
|-------------|-----------------------------------------------------|--------------------------------------------|
| `blackhole` | Installs a `blackhole` route for the target         | Hard sink for unwanted destinations        |
| `delete`    | Removes the matching route                          | Killing a pinned/split-tunnel route entry  |

Default mode is `blackhole`.

---

## Architecture

- **Monitoring** — Uses `ip monitor route` (netlink event stream) rather than
  polling, so reactions happen in milliseconds instead of on a fixed interval.
- **Enforcement** — Adds `blackhole <IP>` (or deletes the route, per `MODE`).
- **Single instance** — `flock`-based PID lockfile prevents duplicate processes
  from racing on the same route.
- **Logging** — Append-only log, rotated by `logrotate`, root-readable (`0640`).
- **Supervision** — systemd unit with capability bounding and filesystem
  hardening; restarts on failure.
- **Cleanup** — `SIGINT`/`SIGTERM`/`EXIT` trap removes the PID file and, in
  `blackhole` mode, reverts the injected route.

---

## Requirements

- Linux with `iproute2`
- Kernel with netlink route monitoring support (≥ 3.2 recommended)
- Bash 4+
- Root privileges (or `CAP_NET_ADMIN`) for `ip route` operations

---

## Configuration

Configuration is resolved in this order (later wins):

1. Built-in defaults in the script
2. Sourced file at `$CONFIG_FILE` (default `/etc/route-monitor/config.conf`)
3. Environment variables passed by systemd or the shell

| Variable      | Default                              | Description                                  |
|---------------|--------------------------------------|----------------------------------------------|
| `TARGET_IP`   | *(none — required)*                  | Destination IP to watch                      |
| `MODE`        | `blackhole`                          | `blackhole` or `delete`                      |
| `RETRY_DELAY` | `30`                                 | Seconds between retries on failure           |
| `LOG_FILE`    | `/var/log/route_monitor/monitor.log` | Log destination                              |
| `PIDFILE`     | `/run/route_monitor.pid`             | Lock file path                               |
| `CONFIG_FILE` | `/etc/route-monitor/config.conf`     | Config file to source                        |

Example `/etc/route-monitor/config.conf`:

```conf
TARGET_IP="<IP>"
MODE="blackhole"
RETRY_DELAY="30"
LOG_FILE="/var/log/route_monitor/monitor.log"
```

> **Note:** the `delete` mode issues a bare `ip route del <IP>` with no
> `via`/`dev` qualifier, so it succeeds regardless of how the route was
> installed. The original script's `via <GW> dev <IFACE>` form failed silently
> whenever the route's next hop differed.

---

## Usage

Foreground (for testing):

```bash
sudo CONFIG_FILE=/etc/route-monitor/config.conf ./route_monitor.sh
```

Background, ad hoc:

```bash
sudo nohup ./route_monitor.sh >/dev/null 2>&1 &
```

Inspect the log:

```bash
sudo tail -f /var/log/route_monitor/monitor.log
```

Verify the event stream independently:

```bash
sudo ip monitor route
```

Override mode for a one-off run:

```bash
sudo MODE=delete ./route_monitor.sh
```

Stop a foreground instance with `Ctrl+C` — the trap handles cleanup. For a
background instance, `sudo systemctl stop route-monitor.service` if installed
via systemd, otherwise `sudo pkill -f route_monitor.sh`.

---

## Security considerations

- Runs as **root** by necessity. The shipped systemd unit constrains this with
  `CapabilityBoundingSet`, `ProtectSystem=strict`, `PrivateTmp`, and
  `ProtectHome`.
- Logs are created `0640 root:root` by logrotate — not world-readable.
- No credentials or secrets are stored in the repository.
- **Redact internal addressing before publishing.** The config file contains
  real gateway and interface details; keep the repo private or sanitize them.
- `ReadWritePaths` is scoped to `/var/log/route_monitor` so the process cannot
  write elsewhere on the filesystem.

---

## Troubleshooting

**Service won't start**

```bash
sudo systemctl status route-monitor.service
sudo journalctl -u route-monitor.service -xe
```

Common causes: `TARGET_IP` unset, config file unreadable, or another instance
holding the PID lock.

**No events observed**

```bash
sudo ip monitor route
```

If this produces no output when routes change, the kernel lacks netlink route
monitoring or the process lacks `CAP_NET_ADMIN`.

**Route reappears immediately after enforcement**

Something else on the host is reinstalling it — a DHCP client, VPN agent, or
NetworkManager connection script. Find it with:

```bash
sudo auditctl -w /sbin/ip -p x -k iproute
sudo ausearch -k iproute -i
```

**Blackhole added but traffic still flows**

See *Known limitations* below — a blackhole for an equal-length prefix does not
automatically outrank an existing unicast route.

**Permission denied on `ip route`**

Grant a narrowly scoped sudoers entry instead of blanket root:

```
youruser ALL=(root) NOPASSWD: /usr/sbin/ip route add blackhole *, /usr/sbin/ip route del *
```

---

## Known limitations

- **Prefix precedence.** Adding `blackhole <IP>/32` alongside an existing
  unicast route for the same prefix does not guarantee the blackhole wins. For
  equal prefix lengths the kernel picks the lowest metric; ties generally favour
  the first-installed route. If enforcement must be absolute, either delete the
  original route first or install the blackhole with an explicit low metric
  (`ip route replace blackhole <IP> metric 1`). This is the one place where the
  current script may report success without achieving the intended effect —
  verify with `ip route get <IP>` after deployment.
- **Host-local scope.** Only affects the machine it runs on. Upstream routers
  and other hosts are unaffected.
- **Not a firewall.** For a genuine policy boundary, pair this with an
  `nftables`/`iptables` drop rule. Route manipulation is a blunt instrument.
- **Netlink dependency.** Falls back to no monitoring at all if
  `ip monitor route` exits; the systemd unit's `Restart=on-failure` covers this,
  but a crash-looping process will thrash. Watch `journalctl` after rollout.
- **IPv4-oriented.** IPv6 targets need `ip -6 route` variants throughout.
- **No dry-run mode.** Enforcement happens immediately on detection.

---

## Roadmap

- [ ] Dry-run mode (`DRY_RUN=1`) that logs intended actions only
- [ ] IPv6 support via a family switch
- [ ] `ip route replace blackhole <IP> metric 1` for deterministic precedence
- [ ] Optional nftables backend for true enforcement
- [ ] Prometheus textfile exporter for alerting on enforcement events
- [ ] Unit tests with a mocked `ip` binary

---

## License

None

---

## Disclaimer

Provided as-is for administrative and defensive use on systems you own or are
explicitly authorized to manage. Validate behaviour in a lab before deploying to
production. The authors accept no liability for outages caused by route
manipulation.

---

## Installation

### Manual installation (step by step)

**1. Install the script**

```bash
sudo install -o root -g root -m 0755 route_monitor.sh /usr/local/bin/route_monitor.sh
```

Using `install` rather than `cp` sets ownership and the executable bit in one
step.

**2. Create the config directory and file**

```bash
sudo mkdir -p /etc/route-monitor
sudo tee /etc/route-monitor/config.conf > /dev/null <<'EOF'
TARGET_IP="<IP>"
MODE="blackhole"
RETRY_DELAY="30"
LOG_FILE="/var/log/route_monitor/monitor.log"
EOF
sudo chmod 0640 /etc/route-monitor/config.conf
```

Edit `TARGET_IP` to your actual target before proceeding.

**3. Create the log directory**

```bash
sudo mkdir -p /var/log/route_monitor
sudo chown root:root /var/log/route_monitor
sudo chmod 0750 /var/log/route_monitor
```

**4. Install the systemd unit**

```bash
sudo install -o root -g root -m 0644 route-monitor.service /etc/systemd/system/route-monitor.service
sudo systemctl daemon-reload
sudo systemctl enable --now route-monitor.service
```

**5. Install the logrotate policy**

```bash
sudo install -o root -g root -m 0644 route-monitor.logrotate /etc/logrotate.d/route-monitor
sudo logrotate --debug /etc/logrotate.d/route-monitor
```

**6. Verify**

```bash
sudo systemctl status route-monitor.service
sudo journalctl -u route-monitor.service -n 50 --no-pager
sudo tail -n 20 /var/log/route_monitor/monitor.log
sudo ip route get <IP>
```

The last command should show the blackhole route taking effect. If it shows a
normal next hop instead, read *Known limitations → Prefix precedence*.

### Uninstall

```bash
sudo systemctl disable --now route-monitor.service
sudo rm -f /etc/systemd/system/route-monitor.service
sudo rm -f /etc/logrotate.d/route-monitor
sudo rm -f /usr/local/bin/route_monitor.sh
sudo rm -rf /etc/route-monitor
sudo systemctl daemon-reload
```

Logs in `/var/log/route_monitor/` are intentionally left in place — remove them
separately if you want a clean slate.

### Upgrading

```bash
sudo systemctl stop route-monitor.service
sudo install -o root -g root -m 0755 route_monitor.sh /usr/local/bin/route_monitor.sh
sudo systemctl start route-monitor.service
sudo systemctl status route-monitor.service
```

Config and logrotate files rarely change between versions; diff them against
the repo before overwriting.
