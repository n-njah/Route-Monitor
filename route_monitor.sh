#!/bin/bash
#
# route_monitor.sh — Hardened, event-driven route guard
#
# Watches for a target IP route via netlink (ip monitor route), replaces it
# with a blackhole entry, logs actions, and supports configuration overrides.
#
# Copyright (c) 2026 — MIT License
#

set -euo pipefail

# Default configuration (can be overridden by environment or config file)
CONFIG_FILE="${CONFIG_FILE:-/etc/route-monitor/config.conf}"
PIDFILE="${PIDFILE:-/run/route_monitor.pid}"
LOG_FILE="${LOG_FILE:-/var/log/route_monitor/monitor.log}"

TARGET_IP=""
MODE="${MODE:-blackhole}"           # 'blackhole' or 'delete'
RETRY_DELAY="${RETRY_DELAY:-30}"    # seconds between retries on failure

# Load config if present
if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
fi

# Validation
if [[ -z "${TARGET_IP:-}" ]]; then
    echo "ERROR: TARGET_IP must be set (config file or env)." >&2
    exit 1
fi

if ! ip route get "$TARGET_IP" >/dev/null 2>&1; then
    echo "WARNING: Cannot reach $TARGET_IP for initial validation. Continuing anyway." >&2
fi

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

cleanup() {
    log "Shutdown: cleaning up."
    rm -f "$PIDFILE"
    # Optionally revert blackhole if desired:
    if [[ "$MODE" == "blackhole" ]] && ip route | grep -q "^blackhole ${TARGET_IP} "; then
        ip route del "blackhole ${TARGET_IP}" 2>/dev/null || true
        log "Removed blackhole route on shutdown."
    fi
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# Lockfile to prevent duplicates
exec 9>"$PIDFILE"
if ! flock -n 9; then
    echo "Another instance is already running (PID $(cat "$PIDFILE"))." >&2
    exit 1
fi
echo $$ > "$PIDFILE"

log "=== Route Monitor Started ==="
log "Target IP: $TARGET_IP"
log "Mode: $MODE"
log "Config: $CONFIG_FILE"
log "PID: $$"

# Initial enforcement
ensure_route_guarded() {
    local existing
    existing="$(ip route | grep "$TARGET_IP" || true)"

    if [[ -n "$existing" ]]; then
        log "Existing route found:"
        log "$existing"

        case "$MODE" in
            blackhole)
                ip route add "blackhole ${TARGET_IP}" 2>/dev/null || true
                log "Blackhole route added for $TARGET_IP"
                ;;
            delete)
                # Attempt generic deletion (no via/dev qualifier)
                if ip route | grep -q "$TARGET_IP"; then
                    ip route del "$TARGET_IP" 2>&1 | log
                    log "Attempted deletion of $TARGET_IP"
                fi
                ;;
        esac
    fi
}

ensure_route_guarded

log "Starting event-driven watch (ip monitor route)..."

# Event-driven loop
ip monitor route 2>/dev/null | while IFS= read -r line; do
    log "Event: $line"

    # Match any route referencing our target IP
    if echo "$line" | grep -q "$TARGET_IP"; then
        log "Route event detected for $TARGET_IP"
        ensure_route_guarded
    fi
done
