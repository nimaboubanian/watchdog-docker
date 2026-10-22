#!/usr/bin/env bash
# entrypoint.sh — Watchdog supervisor and config manager for the vpndogs stack.
#
#   entrypoint.sh                  boot: validate -> write selector haproxy.cfg -> daemon loop
#   entrypoint.sh render           print rendered selector haproxy.cfg to stdout
#   entrypoint.sh check [args...]  run stack verification suite
#   entrypoint.sh report [args...] run stack state report
set -euo pipefail

SELECTOR_CONFIG_DIR="${SELECTOR_CONFIG_DIR-/etc/haproxy-selector}"
SELECTOR_PORT="${SELECTOR_PORT-1080}"
LB_HOST="${LB_HOST-vpndogs-sb-clients-lb}"
LB_PORT="${LB_PORT-1081}"
SOFTETHER_HOST="${SOFTETHER_HOST-vpndogs-softether}"
SOFTETHER_PORT="${SOFTETHER_PORT-1082}"
ROUTER_HOST="${ROUTER_HOST-vpndogs-router}"
ROUTER_PORT="${ROUTER_PORT-1070}"

log() { echo "[entrypoint] $*" >&2; }
fatal() { echo "FATAL: $*" >&2; exit 2; }

is_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

is_host() {
    [[ -n "$1" && "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

validate_env() {
    [[ -n "$SELECTOR_CONFIG_DIR" ]] || fatal "SELECTOR_CONFIG_DIR must not be empty"
    is_port "$SELECTOR_PORT"  || fatal "SELECTOR_PORT must be a port in 1..65535, got '$SELECTOR_PORT'"
    is_port "$LB_PORT"        || fatal "LB_PORT must be a port in 1..65535, got '$LB_PORT'"
    is_port "$SOFTETHER_PORT" || fatal "SOFTETHER_PORT must be a port in 1..65535, got '$SOFTETHER_PORT'"
    is_port "$ROUTER_PORT"    || fatal "ROUTER_PORT must be a port in 1..65535, got '$ROUTER_PORT'"
    is_host "$LB_HOST"        || fatal "LB_HOST must be a valid hostname or IP, got '$LB_HOST'"
    is_host "$SOFTETHER_HOST" || fatal "SOFTETHER_HOST must be a valid hostname or IP, got '$SOFTETHER_HOST'"
    is_host "$ROUTER_HOST"    || fatal "ROUTER_HOST must be a valid hostname or IP, got '$ROUTER_HOST'"
}

render_selector_conf() {
    cat <<EOF
global
    log stdout format raw local0

defaults
    mode tcp
    log global
    option tcplog
    option redispatch
    retries 3
    timeout connect 30s
    timeout client  1h
    timeout server  1h
    timeout check   15s

resolvers docker
    nameserver dns 127.0.0.11:53
    hold valid 10s

frontend socks_in
    bind :$SELECTOR_PORT
    default_backend egress

backend egress
    option tcp-check
    tcp-check connect
    tcp-check send-binary 050100
    tcp-check expect binary 0500
    # the second exchange is a SOCKS5 CONNECT to 1.1.1.1:443, so the check
    # completes a full tunnel handshake: through the xray clients that is a
    # fragmented two-hop VLESS handshake, measured at 1-4.6s, and it must
    # fit inside timeout check or the primary is marked down and the stack
    # silently falls back to softether
    tcp-check send-binary 050100010101010101bb
    tcp-check expect binary 0500
    default-server inter 2s fall 3 rise 2 resolvers docker init-addr last,libc,none
    server sb-cluster $LB_HOST:$LB_PORT check
    server softether-fallback $SOFTETHER_HOST:$SOFTETHER_PORT check backup
EOF
}

HERE="$(cd "$(dirname "$0")" && pwd)"

cmd_render() {
    validate_env
    echo "# === selector/haproxy.cfg ==="
    render_selector_conf
}

write_selector_config() {
    local dest="$SELECTOR_CONFIG_DIR/haproxy.cfg"
    mkdir -p "$SELECTOR_CONFIG_DIR"
    render_selector_conf > "$dest.tmp"
    chmod 644 "$dest.tmp"
    mv "$dest.tmp" "$dest"
    log "selector config written to $dest"
}

main() {
    validate_env
    write_selector_config
    if [ "${BOOT_STAGE:-}" = seed-only ]; then
        exit 0
    fi
    log "watchdog up"
    trap 'log "shutting down"; exit 0' TERM INT
    while true; do
        sleep 3600 &
        wait $! || true
    done
}

case "${1:-}" in
    render)
        cmd_render
        ;;
    check)
        shift
        exec "$HERE/check.sh" "$@"
        ;;
    report)
        shift
        exec "$HERE/report.sh" "$@"
        ;;
    *)
        main
        ;;
esac
