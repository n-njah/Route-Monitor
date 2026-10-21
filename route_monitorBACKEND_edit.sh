#!/bin/bash
#
# route_monitor.sh — Unified route/nftables enforcement daemon
#
# Watches for a target IP route via netlink (ip monitor route), enforces
# blocking via configurable backend(s), logs actions, and supports hot-swap
# between ROUTE, NFTABLES, and BOTH modes.
#
# 
#

set -euo pipefail

# Default configuration (can be overridden by environment or config file)
CONFIG_FILE="${CONFIG_FILE:-/etc/route-monitor/config.conf}"
PIDFILE="${PIDFILE:-/run/route_monitor.pid}"
LOG_FILE="${LOG_FILE:-/var/log/route_monitor/monitor.log}"
LOCKFILE="${LOCKFILE:-/run/route_monitor.lock}"

TARGET_IP=""
MODE="${MODE:-blackhole}"           # For route backend: 'blackhole' or 'delete'
BACKEND="${BACKEND:-both}"          # 'route', 'nftables', or 'both'
RETRY_DELAY="${RETRY_DELAY:-30}"    # seconds between retries on failure
NFT_TABLE="${NFT_TABLE:-inet filter}"
NFT_CHAIN="${NFT_CHAIN:-output}"

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

case "$BACKEND" in
    route|nftables|both) ;;
    *)
        echo "ERROR: BACKEND must be 'route', 'nftables', or 'both'." >&2
        exit 1
        ;;
esac

if ! ip route get "$TARGET_IP" >/dev/null 2>&1; then
    echo "WARNING: Cannot reach $TARGET_IP for initial validation. Continuing anyway." >&2
fi

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$PIDFILE")"
mkdir -p "$(dirname "$LOCKFILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$BACKEND] $*" >> "$LOG_FILE"
}

# Lockfile to prevent duplicates
open_lock_fd() {
    exec 9>"$LOCKFILE"
    if ! flock -n 9; then
        echo "Another instance is already running (PID $(cat "$LOCKFILE" 2>/dev/null || echo '?'))." >&2
        exit 1
    fi
    echo $$ > "$PIDFILE"
    flock 9
}

close_lock_fd() {
    rm -f "$PIDFILE" "$LOCKFILE"
}

cleanup() {
    log "Shutdown: cleaning up enforcement rules..."
    
    if [[ "$BACKEND" == "route" ]] || [[ "$BACKEND" == "both" ]]; then
        remove_route_rule
    fi
    
    if [[ "$BACKEND" == "nftables" ]] || [[ "$BACKEND" == "both" ]]; then
        remove_nft_rule
    fi
    
    close_lock_fd
    log "Cleanup complete. Exiting."
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT

open_lock_fd

log "=== Route Monitor Started ==="
log "Target IP: $TARGET_IP"
log "Backend: $BACKEND"
log "Mode: $MODE"
log "Config: $CONFIG_FILE"
log "PID: $$"

##############################################
# ROUTE BACKEND FUNCTIONS
##############################################

add_route_rule() {
    case "$MODE" in
        blackhole)
            ip route replace "blackhole ${TARGET_IP}" metric 1 2>/dev/null || {
                log "WARN: Failed to add blackhole route for $TARGET_IP"
                return 1
            }
            log "Blackhole route added: blackhole ${TARGET_IP} metric 1"
            ;;
        delete)
            ip route del "$TARGET_IP" 2>/dev/null || {
                log "WARN: No route to delete for $TARGET_IP"
                return 1
            }
            log "Route deleted: $TARGET_IP"
            ;;
        *)
            log "ERROR: Unknown mode '$MODE'"
            return 1
            ;;
    esac
    return 0
}

remove_route_rule() {
    # Remove blackhole if present
    if ip route | grep -q "^blackhole ${TARGET_IP} "; then
        ip route del "blackhole ${TARGET_IP}" 2>/dev/null && \
            log "Blackhole route removed: ${TARGET_IP}" || \
            log "WARN: Could not remove blackhole route"
    fi
}

verify_route_block() {
    local result
    result=$(ip route get "$TARGET_IP" 2>&1)
    if echo "$result" | grep -qi "blackhole"; then
        return 0
    elif [[ "$MODE" == "delete" ]] && ! echo "$result" | grep -q "$TARGET_IP"; then
        return 0
    else
        log "WARN: Route verification failed: $result"
        return 1
    fi
}

ensure_route_guarded() {
    local existing
    existing="$(ip route | grep "$TARGET_IP" | grep -v blackhole || true)"

    if [[ -n "$existing" ]]; then
        log "Existing unicast route found:"
        log "$existing"
        
        if ! add_route_rule; then
            log "ERROR: Route enforcement failed"
            return 1
        fi
        
        if ! verify_route_block; then
            log "ERROR: Route verification failed after enforcement"
            return 1
        fi
    fi
    return 0
}

##############################################
# NFTABLES BACKEND FUNCTIONS
##############################################

ensure_nft_table_chain() {
    # Create table if missing
    if ! nft list table "$NFT_TABLE" >/dev/null 2>&1; then
        nft add table "$NFT_TABLE"
        log "Created nftables table: $NFT_TABLE"
    fi

    # Create chain if missing
    if ! nft list chain "$NFT_TABLE" "$NFT_CHAIN" >/dev/null 2>&1; then
        nft add chain "$NFT_TABLE" "$NFT_CHAIN" '{ type filter hook '"${CHAIN_HOOK:-output}"' priority 0 ; policy accept ; }'
        log "Created nftables chain: $NFT_TABLE/$NFT_CHAIN"
    fi
}

add_nft_rule() {
    ensure_nft_table_chain
    
    # Check if rule already exists
    if nft list chain "$NFT_TABLE" "$NFT_CHAIN" | grep -q "$TARGET_IP.*drop"; then
        log "nftables rule already active"
        return 0
    fi
    
    # Add drop rule with logging
    if nft add rule "$NFT_TABLE" "$NFT_CHAIN" ip daddr "$TARGET_IP" log prefix "ROUTE-MONITOR-DROP: " drop; then
        log "nftables drop rule added: $TARGET_IP"
        return 0
    else
        log "ERROR: Failed to add nftables rule for $TARGET_IP"
        return 1
    fi
}

remove_nft_rule() {
    if nft list chain "$NFT_TABLE" "$NFT_CHAIN" 2>/dev/null | grep -q "$TARGET_IP.*drop"; then
        nft delete rule "$NFT_TABLE" "$NFT_CHAIN" ip daddr "$TARGET_IP" drop 2>/dev/null && \
            log "nftables rule removed: $TARGET_IP" || \
            log "WARN: Could not remove nftables rule"
    fi
}

verify_nft_block() {
    if nft list chain "$NFT_TABLE" "$NFT_CHAIN" 2>/dev/null | grep -q "$TARGET_IP.*drop"; then
        return 0
    else
        log "WARN: nftables verification failed - rule not found"
        return 1
    fi
}

ensure_nft_guarded() {
    if ! add_nft_rule; then
        log "ERROR: nftables enforcement failed"
        return 1
    fi
    
    if ! verify_nft_block; then
        log "ERROR: nftables verification failed after enforcement"
        return 1
    fi
    return 0
}

##############################################
# MAIN ENFORCEMENT LOGIC
##############################################

ensure_enforcement() {
    local rc=0
    
    if [[ "$BACKEND" == "route" ]] || [[ "$BACKEND" == "both" ]]; then
        ensure_route_guarded || rc=1
    fi
    
    if [[ "$BACKEND" == "nftables" ]] || [[ "$BACKEND" == "both" ]]; then
        ensure_nft_guarded || rc=1
    fi
    
    if [[ "$rc" -eq 0 ]]; then
        log "All selected backends verified OK"
    else
        log "WARNING: One or more backends failed verification"
    fi
    
    return $rc
}

# Initial enforcement
ensure_enforcement

log "Starting event-driven watch (ip monitor route)..."

##############################################
# EVENT-DRIVEN MONITORING LOOP
##############################################

ip monitor route 2>/dev/null | while IFS= read -r line; do
    log "Event: $line"

    if echo "$line" | grep -q "$TARGET_IP"; then
        log "Route event detected for $TARGET_IP"
        ensure_enforcement
    fi
done
