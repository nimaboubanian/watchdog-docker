# watchdog: minimal Alpine supervisor that renders selector haproxy.cfg and runs
# stack-wide check.sh and report.sh over /var/run/docker.sock.
#
# Base images come via the ArvanCloud mirror: Docker Hub 403s this host's
# egress (docker.io/registry-1.docker.io), gcr.io mirror too.
FROM docker.arvancloud.ir/library/alpine:3.24

RUN apk add --no-cache \
    bash \
    tini \
    curl \
    jq \
    iproute2 \
    docker-cli \
    coreutils

COPY --chmod=755 scripts /usr/local/bin

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
