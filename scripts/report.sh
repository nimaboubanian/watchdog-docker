#!/usr/bin/env bash
# report.sh — stack state snapshot as markdown. Runs inside vpndogs-watchdog.
# Usage:
#   docker exec vpndogs-watchdog report.sh > vpndogs-report.md
#   docker exec vpndogs-watchdog report.sh /path/to/output.md
set -uo pipefail

OUT="${1:--}"
IPURL='https://api.ipify.org'
LAT_URL='https://speed.cloudflare.com/__down?bytes=1'
DL_URL='https://speed.cloudflare.com/__down?bytes=1000000'
UP_URL='https://speed.cloudflare.com/__up'

WATCHDOG=vpndogs-watchdog
ROUTER="${ROUTER_HOST:-vpndogs-router}"
ROUTER_PORT="${ROUTER_PORT:-1070}"
SELECTOR=vpndogs-selector
SELECTOR_CONFIG_DIR="${SELECTOR_CONFIG_DIR:-/etc/haproxy-selector}"
LB=vpndogs-xray-clients-lb
SE=vpndogs-softether
IPSEC=vpndogs-ipsec-inbound
WG=vpndogs-wg-inbound
AWG=vpndogs-awg-inbound
OVPN=vpndogs-ovpn-inbound
TLS=vpndogs-tls-inbound
CONTAINERS=("$WATCHDOG" "$ROUTER" "$SELECTOR" "$LB" vpndogs-xray-client-1 vpndogs-xray-client-2 vpndogs-xray-client-3 vpndogs-xray-client-4 "$SE" "$IPSEC" "$WG" "$AWG" "$OVPN" "$TLS")

UL_BODY=$(mktemp)

# docker inspect prints a stray blank stdout line on missing objects — trim it
state() { docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null | grep -m1 . || echo missing; }
snu()   { [ "$(state "$1")" = running ]; }
hlth()  { docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$1" 2>/dev/null | grep -m1 . || echo missing; }
cip()   { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null | grep -m1 . ; }
insp()  { docker inspect -f "$2" "$1" 2>/dev/null | grep -m1 . || echo -; }
up_mark() { snu "$1" && echo UP || echo DOWN; }

cleanup() { rm -f "$UL_BODY"; }
trap cleanup EXIT

if [ "$OUT" = "-" ]; then
    s() { printf '%s\n' "$*"; }
else
    : > "$OUT"
    s() { printf '%s\n' "$*" >> "$OUT"; }
fi

step_start() { printf '→ %s\n' "$1" >&2; }
step_end()   { return 0; }

# quality_probe <label> <curl proxy-args...>  — appends one table row
quality_probe() {
    local id="$1"; shift
    local ip dl ul
    ip=$(curl -s --retry 2 --retry-all-errors --max-time 8 "$@" "$IPURL" 2>/dev/null) || true
    if [ -z "$ip" ]; then
        s "| \`$id\` | ✗ | - | - | - | unreachable \`($*)\` |"
        return 1
    fi
    dl=$(curl -s -o /dev/null --max-time 30 "$@" -w '%{speed_download}' "$DL_URL" 2>/dev/null || echo 0)
    head -c 1000000 /dev/zero > "$UL_BODY"
    ul=$(curl -s -o /dev/null --max-time 30 "$@" -w '%{speed_upload}' --data-binary @"$UL_BODY" "$UP_URL" 2>/dev/null || echo 0)
    local lat
    lat=$(for _ in 1 2 3 4 5 6; do
        curl -s -o /dev/null --max-time 6 "$@" -w '%{time_total}\n' "$LAT_URL" 2>/dev/null || echo 0
    done | awk '$1+0>0 {c++; sum+=$1; if(min==0||$1<min)min=$1; if($1>max)max=$1}
        END{ if(c==0) print "x", "x", "x";
             else printf "%.2fs avg, %.2fs jitter", sum/c, max-min }')
    mb(){ awk -v b="$1" 'BEGIN{ b+=0; if (b<10) print "×"; else printf "%.2f MB/s", b/1048576 }'; }
    s "| \`$id\` | $ip | $(mb "$dl") | $(mb "$ul") | $lat |"
}

step_start "hosts & containers"
s "# vpndogs report — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
s ""
s "- kernel: \`$(uname -r)\`, load: $(uptime | sed 's/^.*load average://')"
s "- disk /: $(df -h / | awk 'NR==2{printf "%s free of %s (%s used)",$4,$2,$5}')"
s ""

s "## Containers"
s ""
s "| container | status | health | started at (UTC) | restarts | image |"
s "|---|---|---|---|---|---|"
for c in "${CONTAINERS[@]}"; do
    case "$(state "$c")" in
        running)
            s "| \`$c\` | running | $(hlth "$c") | $(insp "$c" '{{.State.StartedAt}}' | cut -c1-19) | $(insp "$c" '{{.RestartCount}}') | \`$(insp "$c" '{{.Config.Image}}')\` |"
            ;;
        missing)
            s "| \`$c\` | not created (profile off) | - | - | - | - |"
            ;;
        *)
            s "| \`$c\` | $(state "$c") | $(hlth "$c") | - | $(insp "$c" '{{.RestartCount}}') | - |"
            ;;
    esac
done
s ""
step_end

step_start "topology"
s "## Topology"
s ""
s '```'
w=$(up_mark "$WATCHDOG"); r=$(up_mark "$ROUTER"); sel=$(up_mark "$SELECTOR"); lbm=$(up_mark "$LB")
s "watchdog [$w] ──► selector-config + stack supervision"
s "local socks/http :$ROUTER_PORT ──► router [$r]"
[ "$r" = UP ] && {
    s "    ├─ reject rulesets ─────► blackhole (ads/malware/phishing/mining)"
    s "    ├─ ir rulesets ─────────► direct (→ host gateway)"
    s "    └─ everything else ────► proxy-out ──► selector :1080 [$sel]"
}
[ "$r" = UP ] && [ "$sel" = UP ] && {
    s "                                             └─► $LB [$lbm] roundrobin :1081"
    for n in 1 2 3 4; do
        if snu "vpndogs-xray-client-$n"; then
            s "                                                  ├─ xray$n ●"
        else
            s "                                                  ├─ xray$n ○ down"
        fi
    done
    s "                                                  └─ (per-node egress below)"
    if [ "$(up_mark "$SE")" = UP ]; then
        s "                          backup ───────────────► $SE ● gost :1082"
    else
        s "                          backup ───────────────► $SE ○ (no failover)"
    fi
}
[ "$(up_mark "$IPSEC")" = UP ] && s " ipsec-inbound ● UDP 500/4500/1061 → tun0 → router :$ROUTER_PORT"
[ "$(up_mark "$WG")"    = UP ] && s " wg-inbound  ● UDP 1062 → tun0 → router :$ROUTER_PORT"
[ "$(up_mark "$AWG")"   = UP ] && s " awg-inbound ● UDP 1063 → tun0 → router :$ROUTER_PORT"
[ "$(up_mark "$OVPN")"  = UP ] && s " ovpn-inbound ● TCP 1064 → tun0 → tun1 → router :$ROUTER_PORT"
[ "$(up_mark "$TLS")"   = UP ] && s " tls-inbound ● TCP 80/443 + 127.0.0.1:1065 → router :$ROUTER_PORT"
s '```'
s ""
step_end

step_start "inbounds & connected IPs"
s "## Inbounds — connected IPs"
s ""
if snu "$ROUTER"; then
    s "router \`:$ROUTER_PORT\` established:"
    s '```'
    s "$(docker exec "$ROUTER" sh -c "ss -tn 'sport = :$ROUTER_PORT' 2>/dev/null || netstat -tn 2>/dev/null | grep ':$ROUTER_PORT '" 2>/dev/null || true)"
    s '```'
    s ""
fi
if [ "$(up_mark "$IPSEC")" = UP ]; then
    s "**$IPSEC** — UDP 500/4500/1061, SAs:"
    s '```'
    s "$(docker exec "$IPSEC" swanctl --list-sas 2>/dev/null || true)"
    s '```'
    s ""
fi
if [ "$(up_mark "$WG")" = UP ]; then
    s "**$WG** — UDP 1062, peers:"
    s '```'
    s "$(docker exec "$WG" wg show wg0 2>/dev/null || true)"
    s '```'
    s ""
fi
if [ "$(up_mark "$AWG")" = UP ]; then
    s "**$AWG** — UDP 1063, peers:"
    s '```'
    s "$(docker exec "$AWG" awg show awg0 2>/dev/null || true)"
    s '```'
    s ""
fi
if [ "$(up_mark "$OVPN")" = UP ]; then
    s "**$OVPN** — TCP 1064, connected clients:"
    s '```'
    s "$(docker exec "$OVPN" cat /etc/openvpn/status.log 2>/dev/null || true)"
    s '```'
    s ""
fi
if [ "$(up_mark "$TLS")" = UP ]; then
    s "**$TLS** — TCP 80/443 + 127.0.0.1:1065:"
    s '```'
    s "$(docker exec "$TLS" report.sh 2>/dev/null || true)"
    s '```'
    s ""
fi
if ! snu "$IPSEC" && ! snu "$WG" && ! snu "$AWG" && ! snu "$OVPN" && ! snu "$TLS"; then
    s "_no VPN inbound nodes running (profiles off)_"
    s ""
fi
step_end

step_start "routing rules"
s "## Routing rules (live router config)"
s ""
if snu "$ROUTER"; then
    s '```'
    s "$(docker exec "$ROUTER" cat /etc/sing-box/config.json 2>/dev/null | jq -r '
        "final: \(.route.final // "?")",
        (.route.rules[] |
            .outbound as $o | .action as $a |
            [ to_entries[]
              | select(.key != "outbound" and .key != "action")
              | "\(.key)=\(.value | tostring | .[0:100])" ]
            | join(" ") + " → \($o // $a // "?")")' 2>/dev/null || true)"
    s '```'
else
    s "_router not running_"
fi
s ""
step_end

step_start "outbound quality (~1-2 min)"
s "## Outbound quality (1MB, cloudflare speed endpoints)"
s ""
s "| outbound | egress IP | download | upload | latency |"
s "|---|---|---|---|---|"
quality_probe "direct (host)" --noproxy '*' || true
[ "$(up_mark "$ROUTER")" = UP ] && quality_probe "cluster (via :$ROUTER_PORT)" --socks5-hostname "$ROUTER:$ROUTER_PORT" || true
for n in 1 2 3 4; do
    cc=vpndogs-xray-client-$n
    snu "$cc" || continue
    ipp=$(cip "$cc")
    quality_probe "xray$n ($cc)" --socks5-hostname "$ipp:1081" || true
done
[ "$(up_mark "$SE")" = UP ] && quality_probe "softether (gost :1082)" --proxy "http://$(cip "$SE"):1082" || true
s ""
s "_egress IP via api.ipify.org; latency = 6× tiny GET (avg + max−min jitter); down/up = 1MB via cloudflare speed endpoints; direct = host gateway; cluster = the real path router→selector→lb_"
s ""
step_end

step_start "load balancer policies"
s "## Load balancer policies"
s ""
s "**selector** — primary xray-cluster, backup softether (socks-handshake tcp-check):"
s '```'
if [ -s "$SELECTOR_CONFIG_DIR/haproxy.cfg" ]; then
    s "$(sed -n '/^backend egress/,$p' "$SELECTOR_CONFIG_DIR/haproxy.cfg" 2>/dev/null | grep -v 'checksum\|^resolvers\|^    nameserver\|^    hold ' || true)"
elif snu "$SELECTOR"; then
    s "$(docker exec "$SELECTOR" cat /usr/local/etc/haproxy/haproxy.cfg 2>/dev/null | sed -n '/^backend egress/,$p' | grep -v 'checksum\|^resolvers\|^    nameserver\|^    hold ' || true)"
fi
s '```'
if snu "$SELECTOR"; then
    for tgt in "$LB:1081" "$SE:1082"; do
        h="${tgt%%:*}"; p="${tgt##*:}"
        if docker exec "$SELECTOR" nc -z "$h" "$p" >/dev/null 2>&1; then
            s "- check $h:$p: **UP**"
        else
            s "- check $h:$p: **DOWN**"
        fi
    done
fi
s ""
s "**$LB** — roundrobin:"
s '```'
s "$(docker exec "$LB" cat /usr/local/etc/haproxy/haproxy.cfg 2>/dev/null \
    | sed -n '/^backend /,$p' | grep -v 'checksum' || true)"
if ! snu "$LB"; then s "(not running)"; fi
s '```'
if snu "$LB"; then
    for n in 1 2 3 4; do
        if docker exec "$LB" nc -z "xray$n" 1081 >/dev/null 2>&1; then s "- server xray$n: **UP**"
        else s "- server xray$n: **DOWN**"; fi
    done
fi
s ""
step_end

step_start "last 10 logs per container"
s "## Last 10 logs per container"
s ""
for c in "${CONTAINERS[@]}"; do
    if snu "$c"; then
        s "### $c"
        s '```'
        s "$(docker logs --tail 10 "$c" 2>&1)"
        s '```'
        s ""
    else
        s "### $c — _not running_"
        s ""
    fi
done
step_end

[ "$OUT" != "-" ] && echo "wrote $OUT" >&2
exit 0
