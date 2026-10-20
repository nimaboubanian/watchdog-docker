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
    timeout connect 5s
    timeout client  1h
    timeout server  1h
    timeout check   3s

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
    tcp-check send-binary 050100010101010101bb
    tcp-check expect binary 0500
    default-server inter 2s fall 3 rise 2 resolvers docker init-addr last,libc,none
    server sb-cluster $LB_HOST:$LB_PORT check
    server softether-fallback $SOFTETHER_HOST:$SOFTETHER_PORT check backup
EOF
}

cmd_render() {
    validate_env
    echo "# === selector/haproxy.cfg ==="
    render_selector_conf
}

main() {
    validate_env
}

case "${1:-}" in
    render)
        cmd_render
        ;;
    *)
        main
        ;;
esac
