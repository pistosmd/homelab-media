#!/bin/bash
# VPN watchdog for the mediarr stack (LXC 9696).
#
# Owner: homelab-media.  Live copy: /usr/local/sbin/vpn-watchdog.sh INSIDE LXC 9696.
# THIS FILE IS THE ORIGINAL — edit here, then install.  See README.md.
#
# ---------------------------------------------------------------------------------
# Why this exists
#
# On 2026-06-21 gluetun's OpenVPN tunnel failed a TLS negotiation and exited.  Its PID 1
# stayed alive serving the control API, so Docker reported `Up` for the next seven weeks
# and `restart: unless-stopped` never fired — RestartCount was still 0.  The healthcheck
# *did* mark it `unhealthy` the whole time.  Nothing consumed that signal, so nobody knew
# until someone noticed downloads had stopped.
#
# Two lessons are baked into the checks below:
#
# 1. A restart policy keyed on process exit cannot see a dead service inside a live
#    container.  Only a healthcheck can, and a healthcheck with no consumer is decoration.
#
# 2. Checking gluetun's health alone is NOT enough.  Restarting gluetun rebuilds its
#    network namespace, which strands every container using `network_mode:container:gluetun`
#    — they keep pointing at the dead namespace and end up with only `lo`.  gluetun then
#    reports `healthy` while qBittorrent has no network at all.  So the probe is run from
#    *inside qBittorrent's* namespace: it tests the condition the user actually cares about.
# ---------------------------------------------------------------------------------

set -uo pipefail

VPN_CTR=gluetun
PROBE_CTR=qbittorrent          # probe from the consumer, not the provider
STATE_DIR=/var/lib/vpn-watchdog
FAIL_FILE="$STATE_DIR/consecutive-failures"
LAST_ACTION_FILE="$STATE_DIR/last-action-epoch"
ATTEMPT_FILE="$STATE_DIR/consecutive-repair-attempts"

FAILURES_BEFORE_ACTING=3       # ~15 min at a 5-min timer: rides out provider blips
COOLDOWN_SECONDS=1800          # never repair more than once per 30 min
MAX_ATTEMPTS=4                 # after this, stop thrashing and shout instead

# NTFY_TOPIC comes from /etc/vpn-watchdog.env, which is NOT in git — an ntfy topic is an
# unauthenticated channel, so committing it would publish both read and forge capability.
[ -r /etc/vpn-watchdog.env ] && . /etc/vpn-watchdog.env

mkdir -p "$STATE_DIR"
log() { printf '%s  %s\n' "$(date -Is)" "$*"; }

notify() {  # notify <priority> <title> <body>
  [ -n "${NTFY_TOPIC:-}" ] || { log "WARN: no NTFY_TOPIC, cannot notify"; return; }
  curl -fsS -m 10 \
    -H "Title: $2" -H "Priority: $1" -H "Tags: warning,globe_with_meridians" \
    -d "$3" "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null 2>&1 \
    || log "WARN: ntfy push failed"
}

read_int() { local v; v=$(cat "$1" 2>/dev/null); [ -n "$v" ] && printf '%s' "$v" || printf '0'; }

# --- the probe ---------------------------------------------------------------------
# Returns the public IP as seen from inside PROBE_CTR, or nothing.
probe_public_ip() {
  docker exec "$PROBE_CTR" sh -c \
    'curl -s -m 8 https://ipinfo.io/ip 2>/dev/null || wget -qO- -T8 https://ipinfo.io/ip 2>/dev/null' \
    2>/dev/null | tr -d '[:space:]'
}

# The container's own IP, i.e. what we would leak from if the tunnel were bypassed.
host_public_ip() {
  curl -s -m 8 https://ipinfo.io/ip 2>/dev/null | tr -d '[:space:]'
}

has_tunnel() { docker exec "$PROBE_CTR" sh -c 'ip -o addr 2>/dev/null | grep -q tun0'; }

# --- the repair --------------------------------------------------------------------
# Dependents are discovered rather than hardcoded: anything sharing gluetun's namespace.
# Hardcoding would silently miss a container added later, which is the same class of
# mistake as the healthcheck nobody read.
dependents() {
  local gid; gid=$(docker inspect --format '{{.Id}}' "$VPN_CTR" 2>/dev/null) || return
  docker ps --format '{{.Names}}' | while read -r c; do
    [ "$c" = "$VPN_CTR" ] && continue
    [ "$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$c" 2>/dev/null)" = "container:$gid" ] \
      && printf '%s\n' "$c"
  done
}

repair() {
  local deps; deps=$(dependents | tr '\n' ' ')
  log "repairing: restarting $VPN_CTR, then dependents: ${deps:-<none>}"

  docker restart "$VPN_CTR" >/dev/null 2>&1 || { log "ERROR: could not restart $VPN_CTR"; return 1; }

  # Wait for the tunnel before touching dependents. Restarting them against a namespace
  # that is still being rebuilt just strands them again.
  local i
  for i in $(seq 1 30); do
    [ "$(docker inspect --format '{{.State.Health.Status}}' "$VPN_CTR" 2>/dev/null)" = "healthy" ] && break
    sleep 5
  done

  # shellcheck disable=SC2086
  [ -n "$deps" ] && docker restart $deps >/dev/null 2>&1
  sleep 20
}

# --- main --------------------------------------------------------------------------
IP=$(probe_public_ip)
NOW=$(date +%s)

if [ -n "$IP" ] && has_tunnel; then
  MYIP=$(host_public_ip)
  if [ -n "$MYIP" ] && [ "$IP" = "$MYIP" ]; then
    # The tunnel is up but traffic is taking the same exit as unprotected traffic.
    # Alerting only, deliberately: gluetun's firewall is the control, this is the
    # observer, and stopping a download client on a possibly-wrong reading from a
    # third-party IP service is its own kind of damage. A human should look.
    log "LEAK: $PROBE_CTR public IP == host public IP ($IP)"
    notify max "VPN LEAK on mediarr" "$PROBE_CTR is exiting via $IP, the same address as unprotected traffic. Tunnel present but not carrying traffic. Investigate before downloading anything."
    exit 1
  fi
  if [ "$(read_int "$FAIL_FILE")" -gt 0 ] || [ "$(read_int "$ATTEMPT_FILE")" -gt 0 ]; then
    log "recovered: $PROBE_CTR exits via $IP"
    notify default "VPN recovered on mediarr" "$PROBE_CTR is back on the tunnel, exiting via $IP."
  fi
  echo 0 > "$FAIL_FILE"; echo 0 > "$ATTEMPT_FILE"
  log "ok: $PROBE_CTR exits via $IP"
  exit 0
fi

FAILS=$(( $(read_int "$FAIL_FILE") + 1 ))
echo "$FAILS" > "$FAIL_FILE"
log "probe failed ($FAILS/$FAILURES_BEFORE_ACTING) — no tunnel or no route out of $PROBE_CTR"
[ "$FAILS" -lt "$FAILURES_BEFORE_ACTING" ] && exit 0

SINCE=$(( NOW - $(read_int "$LAST_ACTION_FILE") ))
if [ "$SINCE" -lt "$COOLDOWN_SECONDS" ]; then
  log "in cooldown (${SINCE}s of ${COOLDOWN_SECONDS}s) — not repairing"
  exit 0
fi

ATTEMPTS=$(( $(read_int "$ATTEMPT_FILE") + 1 ))
echo "$ATTEMPTS" > "$ATTEMPT_FILE"
if [ "$ATTEMPTS" -gt "$MAX_ATTEMPTS" ]; then
  # Repeated restarts have not fixed it, so the cause is upstream — expired credentials,
  # a stale server list, the provider being down. Thrashing hourly helps nobody and
  # trains you to ignore the alert.
  log "GIVING UP after $ATTEMPTS attempts — needs a human"
  notify max "VPN DOWN on mediarr — giving up" "$MAX_ATTEMPTS restarts have not restored the tunnel. Likely causes: stale gluetun server list (docker pull qmcgaw/gluetun:latest and recreate), expired ProtonVPN credentials, or the provider is down. qBittorrent is sealed off by the killswitch until this is fixed."
  echo "$NOW" > "$LAST_ACTION_FILE"
  exit 1
fi

echo "$NOW" > "$LAST_ACTION_FILE"
notify high "VPN down on mediarr — repairing" "Tunnel unreachable from $PROBE_CTR after $FAILS checks. Restarting gluetun and its dependents (attempt $ATTEMPTS/$MAX_ATTEMPTS)."
repair

IP=$(probe_public_ip)
if [ -n "$IP" ] && has_tunnel; then
  log "repair succeeded: $PROBE_CTR exits via $IP"
  notify default "VPN restored on mediarr" "Back up, exiting via $IP (after $ATTEMPTS attempt(s))."
  echo 0 > "$FAIL_FILE"; echo 0 > "$ATTEMPT_FILE"
  exit 0
fi

log "repair did not restore connectivity"
exit 1
