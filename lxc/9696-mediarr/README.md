# LXC 9696 — mediarr

The arr stack plus qBittorrent, all behind Gluetun/ProtonVPN. Docker-in-LXC.

Running containers as of 2026-08-09: `gluetun`, `qbittorrent`, `nicotine`, `port-sync`,
`sonarr`, `radarr`, `lidarr`, `bazarr`, `prowlarr`, `sabnzbd`, `flaresolverr`.

## The topology, and the two ways it fails

`qbittorrent`, `nicotine` and `port-sync` all run with
`network_mode: container:gluetun`. They have **no network stack of their own** — they live
inside gluetun's namespace, and gluetun publishes their ports. Combined with
`FIREWALL_ENABLED_DISABLING_IT_SHOOTS_YOU_IN_YOUR_FOOT=on`, that means no tunnel ⇒ no
traffic, which is the point: there is no configuration in which qBittorrent reaches the
internet outside the VPN.

It also means the stack has two distinct failure modes, and **the obvious health check
only catches one of them.**

### Failure 1 — the tunnel dies while the container lives

On **2026-06-21** gluetun's OpenVPN tunnel failed a TLS negotiation and its openvpn process
exited. gluetun's PID 1 stayed alive serving the control API, so:

```
docker ps    →  gluetun   Up 4 months (unhealthy)
RestartCount →  0
```

Docker reported `Up`. `restart: unless-stopped` never fired, because **it triggers on
process exit and PID 1 never exited.** The healthcheck correctly said `unhealthy` — for
seven weeks — and nothing consumed that signal. It was noticed only when someone wondered
why downloads had stopped.

The cause was gluetun's bundled ProtonVPN server list going stale (image built 2026-03-01;
Proton rotates server IPs). A restart picked a live server and the tunnel came straight
back up.

### Failure 2 — the namespace is rebuilt underneath the dependents

`docker restart gluetun` tears down and recreates its network namespace. The dependents
keep referring to the **old, dead** namespace and end up with only `lo`:

```
qbittorrent:  lo 127.0.0.1/8          ← no eth0, no tun0
gluetun:      healthy
```

So gluetun reports healthy while qBittorrent has no network at all. **Every repair must
restart gluetun *and then* its dependents**, in that order, waiting for the tunnel in
between — restarting them against a namespace still being rebuilt just strands them again.

## The watchdog

| Repo copy | Live location (inside LXC 9696) |
|---|---|
| `vpn-watchdog.sh` | `/usr/local/sbin/vpn-watchdog.sh` (0750) |
| `vpn-watchdog.service`, `.timer` | `/etc/systemd/system/` |
| — | `/etc/vpn-watchdog.env` — holds `NTFY_TOPIC`, **not in git** |

Install:

```bash
scp lxc/9696-mediarr/vpn-watchdog.* pve:/tmp/
ssh pve 'pct push 9696 /tmp/vpn-watchdog.sh /usr/local/sbin/vpn-watchdog.sh --perms 750
         pct push 9696 /tmp/vpn-watchdog.service /etc/systemd/system/vpn-watchdog.service --perms 644
         pct push 9696 /tmp/vpn-watchdog.timer   /etc/systemd/system/vpn-watchdog.timer   --perms 644
         pct exec 9696 -- systemctl daemon-reload
         pct exec 9696 -- systemctl enable --now vpn-watchdog.timer'
```

**It probes from `qbittorrent`, not from `gluetun`.** Fetching the public IP from inside the
consumer's namespace tests the condition that actually matters and catches *both* failure
modes above; a gluetun-health check catches only the first. Dependents are **discovered**
at repair time by matching `NetworkMode == container:<gluetun id>`, not hardcoded — a
hardcoded list would silently miss a container added later, which is the same class of
mistake as a healthcheck nobody reads.

Behaviour: 5-minute timer, **3 consecutive failures** before acting (~15 min, rides out
provider blips), **30-minute cooldown** between repairs, and it **gives up after 4
attempts** with a loud alert. Giving up is deliberate — if four restarts have not fixed it
the cause is upstream (expired credentials, stale server list, provider outage), and
restarting hourly forever only trains you to ignore the notification.

### The leak check

If the tunnel is up but qBittorrent's public IP equals the container's *own* public IP,
that is a leak: traffic is present but not going through the VPN. The watchdog sends a
`max` priority alert and **does nothing else, on purpose.** gluetun's firewall is the
control; this script is the observer. Stopping a download client on a possibly-wrong
reading from a third-party IP service is its own kind of damage. A human should look.

### Notifications

Pushes to `ntfy.sh` — the same topic the Proxmox host uses, so alerts land in one place.
The topic lives only in `/etc/vpn-watchdog.env` (0600) and in the host's
`/etc/pve/notifications.cfg`. **It is deliberately not committed:** an ntfy topic is an
unauthenticated channel, so publishing it would hand out both the ability to read your
alerts and the ability to forge them.

Verified working at install (`HTTP 200` from inside the container). That check is not
ceremony — an alerting path nobody has tested is precisely what produced the seven-week
outage above.

## Manual recovery, if the watchdog has given up

```bash
ssh pve 'pct exec 9696 -- docker logs --tail 200 gluetun 2>&1 | grep -viE "http server|portforward"'
```

The port-sync poller writes two log lines a minute, so **the VPN lines are always buried** —
filter them out first or you will conclude, wrongly, that nothing has happened.

1. `docker restart gluetun`, then `docker restart qbittorrent nicotine port-sync`
2. Still failing with TLS errors ⇒ stale server list:
   `docker pull qmcgaw/gluetun:latest` and recreate the container
3. Consider `VPN_TYPE=wireguard`. Proton's WireGuard needs no server-list freshness and is
   more reliable than their OpenVPN; it wants a private key from the Proton dashboard.
