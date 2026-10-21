### Backend Configuration

The daemon supports three enforcement backends:

| Backend    | Effect                                            |
|------------|---------------------------------------------------|
| `route`    | Blackhole/delete routing table entry only         |
| `nftables` | Packet filter drop rule only                     |
| `both`     | Applies both methods (recommended for defense)   |

Configure via `/etc/route-monitor/config.conf`:

```conf
BACKEND="both"   # or "route" or "nftables"
```
For nftables backend, ensure the nftables service is enabled:
```bash
sudo systemctl enable --now nftables
sudo nft list ruleset
```
Verify both enforcement channels after startup:
```bash
# Route check
sudo ip route get <IP>
```
## nftables check  
```bash
sudo nft list chain inet filter output
```

---

# (Optional) Testing the Enforcement
Simulate a route addition and verify automatic removal:

## Start the daemon
```bash
sudo systemctl start route-monitor.service
```

## Add a test route (replace YOUR_GW with actual gateway)
```bash
sudo ip route add <IP> via YOUR_GW dev eth0
```

## Verify blocking
```bash
ping -c 1 <IP>
sudo nft list chain inet filter output
sudo tail -f /var/log/route_monitor/monitor.log
```
You should see:
    1. Daemon detects route via netlink event 
    2. Blackhole route added AND/OR nftables rule active 
    3. Ping returns "Operation not permitted" (blackhole) or no response (drop) 

---

# 1. `BACKEND` Comparison Summary

| Metric | `route` | `nftables` | `both` |
|--------|---------|------------|--------|
| Reaction Time | ~10ms (netlink) | ~10ms (netlink) | ~10ms (netlink) |
| Enforcement Strength | Medium (routing bypass possible) | High (packet drop) | Maximum |
| Persistence Across Reboot | Via systemd | Via nftables service + ruleset | Both |
| Audit Trail | Log file | nft counters + log | Dual logging |
| Complexity | Low | Medium | Medium-high |
| Recommended For | Split-tunnel cleanup | Policy enforcement | Production defense |

---

# 2. Git Changes to Push

After saving all files, stage and commit:

```bash
git add route_monitor.sh README.md
git status

# Update .gitignore if needed
cat >> .gitignore <<'EOF'
/etc/route-monitor/
/var/log/route_monitor/
/run/route_monitor*
EOF

git commit -m "feat: add multi-backend enforcement (route/nftables/both)"
git push origin main
```

---

# 3. /etc/route-monitor/config.conf
```bash
# /etc/route-monitor/config.conf
# Configuration for route-monitor daemon

# Target IP to protect/block
TARGET_IP="<IP>"

# Enforcement backend (route|nftables|both)
BACKEND="both"

# Route backend mode (blackhole|delete)
MODE="blackhole"

# Retry delay if enforcement fails (seconds)
RETRY_DELAY="30"

# nftables table/chain (optional, defaults below apply)
# NFT_TABLE="inet filter"
# NFT_CHAIN="output"
# CHAIN_HOOK="output"  # Options: input, output, forward

# Paths (defaults apply if uncommented)
# CONFIG_FILE="/etc/route-monitor/config.conf"
# PIDFILE="/run/route_monitor.pid"
# LOCKFILE="/run/route_monitor.lock"
# LOG_FILE="/var/log/route_monitor/monitor.log"
```

---

# 4. /etc/systemd/system/route-monitor.service
```bash
[Unit]
Description=Route Monitor Daemon (multi-backend)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/route_monitor.sh
Environment=CONFIG_FILE=/etc/route-monitor/config.conf
Restart=on-failure
RestartSec=10
User=root

StandardOutput=journal
StandardError=journal

# Security hardening
ProtectSystem=strict
PrivateTmp=true
ReadWritePaths=/var/log/route_monitor /run
ProtectHome=yes
NoNewPrivileges=false

# Required capabilities for nftables/ip commands
CapabilityBoundingSet=CAP_NET_ADMIN CAP_SYS_ADMIN NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_SYS_ADMIN NET_RAW

[Install]
WantedBy=multi-user.target
```

---

# 5. /etc/logrotate.d/route-monitor
```bash
/var/log/route_monitor/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    postrotate
        systemctl reload-or-kill route-monitor.service >/dev/null 2>&1 || true
    endscript
}
```

---

# 6. /etc/nftables/route-monitor.rules (Optional Preload)
```bash
#!/usr/sbin/nft -f
#
# /etc/nftables/route-monitor.rules
# Preload base nftables table for route-monitor daemon
#

flush ruleset

table inet filter {
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
```

Load once during setup:
```bash
sudo mkdir -p /etc/nftables
sudo cp route-monitor.rules /etc/nftables/
sudo nft -f /etc/nftables/route-monitor.rules
```
