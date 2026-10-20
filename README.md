# watchdog-docker

Minimal Alpine Linux supervisor container (`nimaboubanian/watchdog`, container name `vpndogs-watchdog`) that manages configuration and stack verification for the `vpndogs` routing stack.

## Responsibilities

1. **First container up:** Boots first in the `vpndogs` stack, validates environment variables, and seeds the HAProxy configuration (`haproxy.cfg`) for `vpndogs-selector` into a shared named volume (`selector-config:/etc/haproxy-selector`).
2. **End-to-end health verification (`check.sh`):** Verifies container health, IPv4-only Docker network enforcement, direct host egress, remote proxy egress, domestic direct routing, blackhole rules, and optional `--failover` recovery.
3. **Stack state snapshot (`report.sh`):** Inspects all stack containers via `/var/run/docker.sock`, live routing rules, inbound connected peers/clients, 1 MB Cloudflare quality probes across each outbound, load balancer policies, and recent container logs.

## Usage in the `vpndogs` stack

Verify the stack:

```sh
docker exec vpndogs-watchdog check.sh
docker exec vpndogs-watchdog check.sh --failover
```

Generate a markdown report:

```sh
docker exec vpndogs-watchdog report.sh > vpndogs-report.md
```

Print the rendered selector `haproxy.cfg`:

```sh
docker exec vpndogs-watchdog entrypoint.sh render
```

## Environment variables

All variables are optional and default to the standard `vpndogs` container names and ports:

| Variable | Default | Meaning |
|---|---|---|
| `SELECTOR_CONFIG_DIR` | `/etc/haproxy-selector` | Directory where `haproxy.cfg` is written at boot |
| `SELECTOR_PORT` | `1080` | Frontend TCP port `vpndogs-selector` binds |
| `LB_HOST` | `vpndogs-sb-clients-lb` | Primary backend hostname in `haproxy.cfg` |
| `LB_PORT` | `1081` | Primary backend port in `haproxy.cfg` |
| `SOFTETHER_HOST` | `vpndogs-softether` | Backup backend hostname in `haproxy.cfg` |
| `SOFTETHER_PORT` | `1082` | Backup backend port in `haproxy.cfg` |
| `ROUTER_HOST` | `vpndogs-router` | Router hostname probed by `check.sh` and `report.sh` |
| `ROUTER_PORT` | `1070` | Router port probed by `check.sh` and `report.sh` |

## Development & testing

Run the local (daemon-free) test suite:

```sh
./scripts/test-render.sh --local
```

Build the image and run the full container test suite:

```sh
./build.sh
./scripts/test-render.sh
```
