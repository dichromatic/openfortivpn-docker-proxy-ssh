# syntax=docker/dockerfile:1
FROM alpine:3.19 AS builder

RUN apk add --no-cache \
    git \
    autoconf \
    automake \
    gcc \
    make \
    musl-dev \
    openssl-dev \
    linux-headers

WORKDIR /build
RUN git clone https://github.com/adrienverge/openfortivpn.git . \
    && autoreconf -i \
    && ./configure --prefix=/usr --sysconfdir=/etc \
    && make -j$(nproc) \
    && make install DESTDIR=/install


FROM alpine:3.19

RUN apk add --no-cache \
    openssl ppp openssh ca-certificates iproute2 shadow socat

COPY --from=builder /install/usr/bin/openfortivpn /usr/bin/openfortivpn

# SSH is initialised at first start, not at build time,
# so host keys and config survive container restarts via the ssh_data volume.

RUN cat > /entrypoint.sh <<'EOF'
#!/bin/sh
set -e

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# First-run SSH initialisation - skipped on subsequent starts because
# the host keys and config are persisted via the ssh_data volume.
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    log "First start: generating SSH host keys and writing sshd_config"
    ssh-keygen -A
    printf 'Port 22\nPermitRootLogin yes\nPasswordAuthentication yes\nAllowTcpForwarding yes\nGatewayPorts yes\nUsePAM no\nUseDNS no\n' \
        > /etc/ssh/sshd_config
fi

mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch /root/.ssh/known_hosts && chmod 600 /root/.ssh/known_hosts

if [ -n "$SSH_PASSWORD" ]; then
    printf "root:%s\n" "$SSH_PASSWORD" | chpasswd
else
    PASS=$(head -c 12 /dev/urandom | base64 | tr -d '\n')
    printf "root:%s\n" "$PASS" | chpasswd
    log "SSH password (auto-generated): $PASS"
fi

# Keep eth0 reachable after the VPN replaces the default route with ppp0
ETH0_IP=$(ip -4 addr show eth0 | awk '/inet /{print $2}' | cut -d/ -f1)
ETH0_GW=$(ip route show default dev eth0 | awk '{print $3}')
ip route add default via "$ETH0_GW" dev eth0 table 100
ip rule add from "$ETH0_IP" lookup 100 prio 100
log "Policy routing: eth0 ($ETH0_IP via $ETH0_GW) pinned to table 100"

# openfortivpn binds its SAML callback server to 127.0.0.1:8020 (loopback only).
# Docker port mapping can't reach loopback, so socat bridges the gap:
# outside -> container:8021 -> socat -> 127.0.0.1:8020 -> openfortivpn
socat TCP-LISTEN:8021,fork,reuseaddr TCP:127.0.0.1:8020 &
log "SAML relay listening on :8021 -> loopback:8020"

/usr/sbin/sshd
log "SSH proxy ready on :22"

CERT_FLAG=""
[ -n "$TRUSTED_CERT" ] && CERT_FLAG="--trusted-cert $TRUSTED_CERT"

# Keep-alive: disabled by default. Set KEEPALIVE=1 in .env to enable.
# Pings the ppp0 peer every 25s to prevent idle session timeout.
if [ "${KEEPALIVE:-0}" = "1" ]; then
    log "Keep-alive enabled - pinging ppp0 peer every 25s"
    ( while true; do
        if ip link show ppp0 >/dev/null 2>&1; then
            PEER=$(ip addr show ppp0 2>/dev/null | awk '/peer/{gsub(/\/.*/,"",$4); print $4; exit}')
            [ -n "$PEER" ] && ping -c 1 -W 5 "$PEER" >/dev/null 2>&1
        fi
        sleep 25
    done ) &
fi

# Reconnect loop - if the session is dropped (FortiGate 30-min limit or otherwise)
# openfortivpn exits, we wait 5s and start again. SAML auth will be required again.
while true; do
    log "Starting openfortivpn -> $*"

    # shellcheck disable=SC2086
    openfortivpn --saml-login -v $CERT_FLAG "$@" 2>&1 | while IFS= read -r line; do
        TS=$(date '+%Y-%m-%d %H:%M:%S')

        case "$line" in
            *"Authenticate at '"*)
                URL=$(printf '%s\n' "$line" | grep -o "https://[^']*")
                printf '[%s] [AUTH ] SAML login required\n' "$TS"
                echo ""
                echo "============================================================"
                echo "  1. Open in your browser:"
                echo "     $URL"
                echo ""
                echo "  2. Complete SSO. Browser will redirect to 127.0.0.1:8020"
                echo "     and show an error - that is expected."
                echo ""
                echo "  3. Copy the full URL from the address bar and run:"
                echo "     curl 'http://SERVER_IP:8020/<paste?id=... here>'"
                echo "============================================================"
                echo ""
                ;;
            *"Processing HTTP SAML"*)
                printf '[%s] [AUTH ] SAML token received\n' "$TS" ;;
            *"Tunnel is up"*|*"tunnel is up"*)
                printf '[%s] [UP   ] %s\n' "$TS" "$line" ;;
            *"ppp"*"up"*|*"Interface"*"up"*)
                printf '[%s] [PPP  ] %s\n' "$TS" "$line" ;;
            *"Adding route"*|*"route"*)
                printf '[%s] [ROUTE] %s\n' "$TS" "$line" ;;
            *"DNS"*)
                printf '[%s] [DNS  ] %s\n' "$TS" "$line" ;;
            *"Logged in"*|*"logged in"*)
                printf '[%s] [AUTH ] %s\n' "$TS" "$line" ;;
            *"ERROR"*|*"error"*)
                printf '[%s] [ERROR] %s\n' "$TS" "$line" ;;
            *"WARN"*|*"warn"*)
                printf '[%s] [WARN ] %s\n' "$TS" "$line" ;;
            *"Disconnected"*|*"disconnected"*|*"closed"*)
                printf '[%s] [DOWN ] %s\n' "$TS" "$line" ;;
            *"INFO"*)
                printf '[%s] [INFO ] %s\n' "$TS" "${line#*INFO:  }" ;;
            *)
                printf '[%s] [VPN  ] %s\n' "$TS" "$line" ;;
        esac
    done

    log "VPN exited - reconnecting in 5s..."
    sleep 5
done
EOF

RUN chmod +x /entrypoint.sh

# 22   = SSH proxy
# 8021 = socat relay -> openfortivpn's SAML callback server on loopback:8020
EXPOSE 22 8021

ENTRYPOINT ["/entrypoint.sh"]
