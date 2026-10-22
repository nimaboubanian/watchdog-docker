#!/usr/bin/env bash
# test-render.sh — watchdog suite.
#   ./scripts/test-render.sh --local   render/validation/seed/script cases only, no daemon
#   ./scripts/test-render.sh           everything, against $IMG
set -uo pipefail

IMG="${IMAGE:-watchdog:latest}"
MODE=docker
[ "${1:-}" = "--local" ] && MODE=local

HERE="$(cd "$(dirname "$0")" && pwd)"
ENTRY="$HERE/entrypoint.sh"
fail=0
LAST_OUT=""

FIX_ENV=()
FIX_DE=()

run_env() {
    local host_env=("${FIX_ENV[@]}") docker_env=("${FIX_DE[@]}") kv args=()
    for kv in "$@"; do
        if [[ "$kv" == *=* ]]; then
            host_env+=("$kv")
            docker_env+=(-e "$kv")
        else
            args+=("$kv")
        fi
    done
    if [ "$MODE" = local ]; then
        env "${host_env[@]}" bash "$ENTRY" "${args[@]}" 2>&1
    else
        docker run --rm --network none "${docker_env[@]}" \
            --entrypoint /usr/local/bin/entrypoint.sh "$IMG" "${args[@]}" 2>&1
    fi
}

block() { printf '%s\n' "$2" | awk -v b="# === $1 ===" '$0==b{f=1;next} /^# === /{f=0} f'; }

eq() { local name="$1" got="$2" want="$3"; [ "$got" = "$want" ] && echo "$name: PASS" || { echo "$name: FAIL"; printf 'want:\n%s\n\ngot:\n%s\n' "$want" "$got" >&2; fail=1; }; }
ok() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "$name: PASS"; else echo "$name: FAIL"; fail=1; fi; }
has() { local name="$1" text="$2" pat="$3"; printf '%s\n' "$text" | grep -qF -- "$pat" && echo "$name: PASS" || { echo "$name: FAIL"; printf 'expected %q in:\n%s\n' "$pat" "$text" >&2; fail=1; }; }
lacks() { local name="$1" text="$2" pat="$3"; printf '%s\n' "$text" | grep -qF -- "$pat" && { echo "$name: FAIL"; printf 'found %q in:\n%s\n' "$pat" "$text" >&2; fail=1; } || echo "$name: PASS"; }

run_is() {
    local name="$1" want="$2" rc=0 _tmp
    shift 2
    _tmp="$(mktemp)"
    set +e; "$@" > "$_tmp" 2>&1; rc=$?
    LAST_OUT="$(cat "$_tmp")"; rm -f "$_tmp"
    if [ "$rc" = "$want" ]; then
        echo "$name: PASS (exit $rc)"
    else
        echo "$name: FAIL (exit $rc, want $want)"
        printf '%s\n' "$LAST_OUT" >&2
        fail=1
    fi
}

case_validate() {
    echo "=== VALIDATION CASES ==="
    run_is "port 0 rejected"           2 run_env "SELECTOR_PORT=0" render
    has    "names SELECTOR_PORT"       "$LAST_OUT" "SELECTOR_PORT"
    run_is "port 65536 rejected"       2 run_env "LB_PORT=65536" render
    has    "names LB_PORT"             "$LAST_OUT" "LB_PORT"
    run_is "non-numeric port rejected" 2 run_env "SOFTETHER_PORT=abc" render
    run_is "negative port rejected"    2 run_env "ROUTER_PORT=-1" render
    run_is "empty LB_HOST rejected"    2 run_env "LB_HOST=" render
    has    "names LB_HOST"             "$LAST_OUT" "LB_HOST"
    run_is "whitespace host rejected"  2 run_env "SOFTETHER_HOST=bad host" render
    run_is "semicolon host rejected"   2 run_env "ROUTER_HOST=host;rm" render
    run_is "empty config dir rejected" 2 run_env "SELECTOR_CONFIG_DIR=" render
}

case_render() {
    echo "=== RENDER CASES ==="
    local out cfg
    run_is "default render exits 0" 0 run_env render
    out="$LAST_OUT"
    cfg="$(block "selector/haproxy.cfg" "$out")"
    has "binds default 1080"       "$cfg" "bind :1080"
    has "docker resolver"          "$cfg" "nameserver dns 127.0.0.11:53"
    has "socks5 tcp-check"         "$cfg" "tcp-check send-binary 050100010101010101bb"
    has "init-addr deferred"       "$cfg" "default-server inter 2s fall 3 rise 2 resolvers docker init-addr last,libc,none"
    has "primary sb-cluster"       "$cfg" "server sb-cluster vpndogs-sb-clients-lb:1081 check"
    has "backup softether"         "$cfg" "server softether-fallback vpndogs-softether:1082 check backup"

    run_is "custom override render" 0 run_env \
        "SELECTOR_PORT=2080" "LB_HOST=custom-lb" "LB_PORT=2081" \
        "SOFTETHER_HOST=custom-se" "SOFTETHER_PORT=2082" render
    cfg="$(block "selector/haproxy.cfg" "$LAST_OUT")"
    has "custom bind port"         "$cfg" "bind :2080"
    has "custom primary backend"   "$cfg" "server sb-cluster custom-lb:2081 check"
    has "custom backup backend"    "$cfg" "server softether-fallback custom-se:2082 check backup"
}

case_seed() {
    echo "=== SEED CASES ==="
    local tmp mode
    tmp="$(mktemp -d)"
    run_is "seed-only writes config and exits 0" 0 \
        env SELECTOR_CONFIG_DIR="$tmp/nested/dir" BOOT_STAGE=seed-only bash "$ENTRY"
    ok  "haproxy.cfg file exists and non-empty" test -s "$tmp/nested/dir/haproxy.cfg"
    mode="$(stat -c '%a' "$tmp/nested/dir/haproxy.cfg" 2>/dev/null || echo missing)"
    eq  "haproxy.cfg mode is 644" "$mode" "644"
    has "seeded file has backend egress" "$(cat "$tmp/nested/dir/haproxy.cfg" 2>/dev/null || true)" "backend egress"
    # the sb-cluster check is a SOCKS5 CONNECT to 1.1.1.1:443, so it
    # completes a full tunnel handshake — through the xray clients that is a
    # fragmented two-hop VLESS handshake (1-4.6s), which must fit inside
    # timeout check or the primary is marked down and the stack silently
    # falls back to softether
    has "seeded file has a check timeout that fits the tunnel" \
        "$(cat "$tmp/nested/dir/haproxy.cfg" 2>/dev/null || true)" "timeout check   15s"
    has "seeded file has a connect timeout that fits the tunnel" \
        "$(cat "$tmp/nested/dir/haproxy.cfg" 2>/dev/null || true)" "timeout connect 30s"
    rm -rf "$tmp"
}

case_scripts() {
    echo "=== SCRIPT & REPORT STREAM CASES ==="
    ok "entrypoint.sh syntax" bash -n "$HERE/entrypoint.sh"
    ok "check.sh syntax"      bash -n "$HERE/check.sh"
    ok "report.sh syntax"     bash -n "$HERE/report.sh"
    has "check.sh waits on watchdog" "$(cat "$HERE/check.sh" 2>/dev/null || true)" "vpndogs-watchdog"
    has "check.sh uses ROUTER_HOST"  "$(cat "$HERE/check.sh" 2>/dev/null || true)" 'ROUTER_HOST:-vpndogs-router'
    has "check.sh traps failover"    "$(cat "$HERE/check.sh" 2>/dev/null || true)" 'trap '\''docker start $names'
    ok  "check.sh registers trap before docker stop" \
        awk '/trap .*docker start \$names/{t=NR} /docker stop \$names/{s=NR} END{exit !(t && s && t < s)}' "$HERE/check.sh"
    has "check.sh verifies tls-inbound"          "$(cat "$HERE/check.sh" 2>/dev/null || true)" 'vpndogs-tls-inbound'
    has "check.sh verifies tls-inbound socks"    "$(cat "$HERE/check.sh" 2>/dev/null || true)" 'vpndogs-tls-inbound:1065'
    has "check.sh verifies tls-inbound fallback" "$(cat "$HERE/check.sh" 2>/dev/null || true)" '127.0.0.1:8080'
    has "check.sh waits for tls-inbound health"  "$(cat "$HERE/check.sh" 2>/dev/null || true)" 'tls_budget='
    # the sb-client healthcheck is a real end-to-end tunnel fetch and the LB
    # only starts once that client is healthy: the readiness budget has to
    # cover it
    has "check.sh budget covers the tunnel healthcheck" \
        "$(cat "$HERE/check.sh" 2>/dev/null || true)" 'budget=180'

    local mockdir out_md err_log
    mockdir="$(mktemp -d)"
    cat <<'EOF' > "$mockdir/docker"
#!/bin/sh
if [ "$1" = "inspect" ] && [ "$3" = "{{.State.Status}}" ]; then
    case "$4" in
        vpndogs-router|vpndogs-tls-inbound) echo "running"; exit 0 ;;
    esac
fi
if [ "$1" = "exec" ]; then
    if [ "$2" = "vpndogs-router" ]; then
        shift 2
        case "$*" in
            *netstat*) echo "tcp 0 0 127.0.0.1:1070 127.0.0.1:54321 ESTABLISHED"; exit 0 ;;
        esac
    elif [ "$2" = "vpndogs-tls-inbound" ]; then
        shift 2
        case "$*" in
            *report.sh*) echo "== Processes =="; echo "sing-box: UP"; echo "nginx: UP"; exit 0 ;;
        esac
    fi
fi
exit 1
EOF
    printf '#!/bin/sh\nexit 1\n' > "$mockdir/curl"
    chmod +x "$mockdir/docker" "$mockdir/curl"
    out_md="$mockdir/stdout.md"
    err_log="$mockdir/stderr.log"
    PATH="$mockdir:$PATH" SELECTOR_CONFIG_DIR="$mockdir" bash "$HERE/report.sh" >"$out_md" 2>"$err_log" || true
    has   "stdout has report header"     "$(cat "$out_md")" "# vpndogs report"
    has   "stdout lists watchdog"        "$(cat "$out_md")" "vpndogs-watchdog"
    has   "stdout lists tls-inbound"     "$(cat "$out_md")" "vpndogs-tls-inbound"
    has   "stdout shows tls topology"    "$(cat "$out_md")" "tls-inbound ● TCP 80/443 + 127.0.0.1:1065"
    has   "stdout shows tls inbounds"    "$(cat "$out_md")" "**vpndogs-tls-inbound** — TCP 80/443 + 127.0.0.1:1065"
    has   "stdout shows router sockets via netstat fallback" "$(cat "$out_md")" "127.0.0.1:54321 ESTABLISHED"
    lacks "stdout has no progress lines" "$(cat "$out_md")" "→ hosts & containers"
    has   "stderr has progress lines"    "$(cat "$err_log")" "→ hosts & containers"
    rm -rf "$mockdir"
}

docker_cases() {
    echo "=== DOCKER CASES ==="
    local vol="watchdog-test-$$" cfg
    docker volume rm -f "$vol" >/dev/null 2>&1 || true
    # Double quotes on purpose: the EXIT trap fires after this function returns,
    # so a single-quoted $vol would be unbound under `set -u`.
    trap "docker volume rm -f '$vol' >/dev/null 2>&1 || true" EXIT
    run_is "container seed-only writes haproxy.cfg" 0 \
        docker run --rm --network none -v "$vol":/etc/haproxy-selector \
            -e BOOT_STAGE=seed-only "$IMG"
    cfg="$(docker run --rm --network none -v "$vol":/etc/haproxy-selector \
        --entrypoint /bin/sh "$IMG" -c 'cat /etc/haproxy-selector/haproxy.cfg')"
    has "container volume has backend egress" "$cfg" "backend egress"
    run_is "container ships required CLI tools" 0 \
        docker run --rm --network none --entrypoint /bin/sh "$IMG" \
            -c 'docker --version && jq --version && curl --version && ss --version'
    docker volume rm -f "$vol" >/dev/null 2>&1 || true
}

main_cases() {
    case_validate
    case_render
    case_seed
    case_scripts
}

main_cases
if [ "$MODE" = docker ]; then
    docker_cases
fi
exit "$fail"
