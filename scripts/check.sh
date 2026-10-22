#!/usr/bin/env bash
set -euo pipefail

ROUTER_HOST="${ROUTER_HOST:-vpndogs-router}"
ROUTER_PORT="${ROUTER_PORT:-1070}"
SOCKS=--socks5-hostname
PROXY="$ROUTER_HOST:$ROUTER_PORT"
FAILOVER=0
[ "${1:-}" = "--failover" ] && FAILOVER=1

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

pass() {
    echo "PASS: $1" >&2
}

wait_containers() {
    # wait until every watchdog/router/sb-client/selector/LB container is healthy
    # (softether only needs `running`: gost answers even if the tunnel is down)
    # 180s, not 120s: the sb-client healthcheck is now a real end-to-end
    # tunnel fetch (interval 30s, start_period 120s) and the LB only starts
    # once that client is healthy, so the critical path grew.
    local budget=180
    while [ $budget -gt 0 ]; do
        local ok=1
        for c in vpndogs-watchdog vpndogs-router vpndogs-selector vpndogs-sb-clients-lb vpndogs-sb-client-1; do
            state=$(docker inspect --format '{{.State.Health.Status}}' "$c" 2>/dev/null || echo missing)
            [ "$state" = healthy ] || ok=0
        done
        se=$(docker inspect --format '{{.State.Status}}' vpndogs-softether 2>/dev/null || echo missing)
        [ "$se" = running ] || ok=0
        if [ $FAILOVER = 1 ]; then
            # failover is only meaningful with a configured fallback. An
            # unconfigured softether crash-loops (entrypoint exits), and
            # `running` reads true in the gap between restarts.
            seh=$(docker inspect --format '{{.State.Health.Status}}' vpndogs-softether 2>/dev/null || echo missing)
            [ "$seh" = healthy ] || ok=0
        fi
        [ $ok = 1 ] && return 0
        sleep 2
        budget=$((budget - 2))
    done
    if [ $FAILOVER = 1 ]; then
        fail "failover needs vpndogs-softether healthy: set VPN_PROFILE (with a *.vpn file in vpn-profiles/) or SE_HOST/SE_PORT/SE_HUB/SE_USER/SE_PASSWORD - see 'docker compose logs vpndogs-softether'"
    fi
    fail "stack containers not healthy within 120s"
}

wait_containers
sleep 5

# canary: the stack network must stay IPv4-only — an IPv6-enabled network
# would let containers egress IPv6 straight from the host, bypassing the
# chain (see README Troubleshooting: dual-stack services blocked)
net=$(docker inspect "$ROUTER_HOST" -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null || true)
v6=$(docker network inspect "$net" -f '{{.EnableIPv6}}' 2>/dev/null || true)
[ "$v6" = "false" ] || fail "stack network '$net' must stay IPv4-only (EnableIPv6=${v6:-unknown})"

# any curl failure here must report, never abort silently under `set -e`
if ! host_ip=$(curl -s --noproxy '*' --max-time 20 https://api.ipify.org) || [ -z "$host_ip" ]; then
    fail "direct egress (host): no IP from the baseline endpoint - internet or DNS is down, retry"
fi

proxy_ip=$(curl -s --retry 2 --retry-all-errors --max-time 20 $SOCKS "$PROXY" https://api.ipify.org || true)
if [ -n "$proxy_ip" ] && [ "$proxy_ip" != "$host_ip" ]; then
    pass "remote egress (proxy: $proxy_ip, host: $host_ip)"
else
    fail "remote egress: proxy IP empty or equals host IP ($proxy_ip)"
fi

code=$(curl -s --retry 2 --retry-all-errors -o /dev/null -w '%{http_code}' --max-time 20 $SOCKS "$PROXY" https://www.aparat.com || true)
if [ "${code:-0}" -ge 200 ] && [ "$code" -lt 400 ]; then
    pass "domestic egress (aparat.com -> HTTP $code)"
else
    fail "domestic egress: HTTP $code"
fi

if curl -s -o /dev/null --max-time 10 $SOCKS "$PROXY" http://googlesyndication.com; then
    fail "blackhole: googlesyndication.com was reachable"
else
    pass "blackhole (googlesyndication.com unreachable)"
fi

if [ "$(docker inspect --format '{{.State.Status}}' vpndogs-tls-inbound 2>/dev/null || echo missing)" = running ]; then
    tls_budget=40
    tlsh="starting"
    while [ $tls_budget -gt 0 ] && [ "$tlsh" = "starting" ]; do
        tlsh=$(docker inspect --format '{{.State.Health.Status}}' vpndogs-tls-inbound 2>/dev/null || echo missing)
        [ "$tlsh" = healthy ] && break
        sleep 2
        tls_budget=$((tls_budget - 2))
    done
    [ "$tlsh" = healthy ] || fail "tls-inbound: container is running but not healthy ($tlsh)"
    tls_ip=$(curl -s --retry 2 --retry-all-errors --max-time 20 $SOCKS vpndogs-tls-inbound:1065 https://api.ipify.org || true)
    if [ -n "$tls_ip" ] && [ "$tls_ip" != "$host_ip" ]; then
        pass "tls-inbound socks :1065 egress (proxy: $tls_ip)"
    else
        fail "tls-inbound socks :1065 egress: IP empty or equals host IP ($tls_ip)"
    fi
    if docker exec vpndogs-tls-inbound curl -fsSL --max-time 5 http://127.0.0.1:8080/ 2>/dev/null | grep -q 'dir="rtl"'; then
        pass "tls-inbound fallback static website (dir=rtl)"
    else
        fail "tls-inbound fallback static website unreachable on 127.0.0.1:8080"
    fi
fi

if [ $FAILOVER = 1 ]; then
    names=$(docker ps --filter 'name=^vpndogs-sb-client-' --format '{{.Names}}')
    [ -n "$names" ] || fail "failover: no running sb-clients to stop"
    trap 'docker start $names > /dev/null 2>&1 || true' EXIT INT TERM
    docker stop $names > /dev/null
    sleep 15

    # ponytail: if-condition, not a bare assignment — under `set -e` a curl error
    # would abort before `docker start`, leaving the sb-clients stopped.
    if failover_ip=$(curl -s --retry 2 --retry-all-errors --max-time 20 $SOCKS "$PROXY" https://api.ipify.org) \
        && [ -n "$failover_ip" ] && [ "$failover_ip" != "$host_ip" ]; then
        pass "failover (egress: $failover_ip)"
    else
        docker start $names > /dev/null
        fail "failover: no egress via softether after clients stopped (${failover_ip:-curl failed})"
    fi

    docker start $names > /dev/null
    budget=120
    restored_ip=""
    restored=0
    while [ $budget -gt 0 ]; do
        if restored_ip=$(curl -s --retry 2 --retry-all-errors --max-time 20 $SOCKS "$PROXY" https://api.ipify.org) && [ -n "$restored_ip" ] && [ "$restored_ip" != "$host_ip" ]; then
            pass "restore (egress: $restored_ip)"
            restored=1
            break
        fi
        sleep 5
        budget=$((budget - 5))
    done
    [ "$restored" = 1 ] || fail "restore: no sb-cluster egress after clients restarted"
fi

echo "all checks passed" >&2
