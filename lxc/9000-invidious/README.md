# LXC 9000 — Invidious

Self-hosted [Invidious](https://github.com/iv-org/invidious) — a privacy-respecting
YouTube frontend. Single-user, behind Cloudflare Access at `invidious.neoprax.is`.

**Status: not yet provisioned.** This directory is the plan; nothing is running.

## Why single-user behind Access

Public Invidious instances get IP-blocked by YouTube aggressively — that's the main
reason the public instance list churns. A private instance serving one person makes far
fewer requests and holds up much better. Keeping it behind Cloudflare Access also means
no registration flow to secure, hence `registration_enabled: false` in the compose.

`popular_enabled` and `statistics_enabled` are off for the same reason: both are
features of public instances, and statistics advertises the instance to crawlers.

## Sizing

| Resource | Value | Why |
|---|---|---|
| RAM | 2048 MB | Invidious ~500MB, postgres ~300MB, companion ~200MB, headroom |
| Disk | 16 GB | Postgres grows slowly with one user; watch it anyway |
| Cores | 2 | |
| Unprivileged | yes | |
| Nesting | 1 | Required — Docker inside LXC |
| Keyctl | 1 | Required — Docker inside unprivileged LXC |

## Provisioning

Run from your workstation. `PVE=pve` on LAN, `pve-remote` otherwise.

### 1. Create the container

```bash
PVE=pve
ssh $PVE 'pct create 9000 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname invidious \
  --cores 2 --memory 2048 --swap 512 \
  --rootfs local-lvm:16 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --features nesting=1,keyctl=1 \
  --unprivileged 1 \
  --onboot 1 \
  --start 1'
```

Check the template exists first: `ssh $PVE 'pveam list local'`. If the Debian 12
template is absent, `pveam update && pveam download local debian-12-standard_...`.

Note the assigned IP — you need it for the tunnel route:

```bash
ssh $PVE 'pct exec 9000 -- hostname -I'
```

### 2. Install Docker

```bash
ssh $PVE 'pct exec 9000 -- bash -c "
  apt-get update && apt-get install -y ca-certificates curl gnupg git &&
  install -m 0755 -d /etc/apt/keyrings &&
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc &&
  chmod a+r /etc/apt/keyrings/docker.asc &&
  echo \"deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable\" > /etc/apt/sources.list.d/docker.list &&
  apt-get update &&
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
"'
```

### 3. Stage the config

The compose file mounts Postgres init scripts that ship with the Invidious source, not
with the image. Clone upstream to get them, then overlay our compose:

```bash
ssh $PVE 'pct exec 9000 -- bash -c "
  git clone --depth 1 https://github.com/iv-org/invidious /tmp/invidious-src &&
  mkdir -p /opt/invidious &&
  cp -r /tmp/invidious-src/config/sql /opt/invidious/sql &&
  cp /tmp/invidious-src/docker/init-invidious-db.sh /opt/invidious/init-invidious-db.sh &&
  chmod +x /opt/invidious/init-invidious-db.sh &&
  rm -rf /tmp/invidious-src
"'
```

Then push this directory's compose file and build the `.env`:

```bash
scp docker-compose.yml $PVE:/tmp/
ssh $PVE 'pct push 9000 /tmp/docker-compose.yml /opt/invidious/docker-compose.yml && rm /tmp/docker-compose.yml'

ssh $PVE 'pct exec 9000 -- bash -c "
  cd /opt/invidious &&
  { echo POSTGRES_PASSWORD=\$(openssl rand -hex 24);
    echo HMAC_KEY=\$(openssl rand -hex 32);
    echo COMPANION_KEY=\$(openssl rand -hex 8); } > .env &&
  chmod 600 .env
"'
```

`COMPANION_KEY` must be exactly 16 characters — `openssl rand -hex 8` gives that. A key
of any other length makes the companion refuse to start, with an error that doesn't
obviously say so.

### 4. Start it

```bash
ssh $PVE 'pct exec 9000 -- bash -c "cd /opt/invidious && docker compose up -d"'
ssh $PVE 'pct exec 9000 -- bash -c "cd /opt/invidious && docker compose ps"'
```

First start takes a minute while Postgres initialises. Verify locally before wiring the
tunnel:

```bash
ssh $PVE 'pct exec 9000 -- curl -sf -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3000/'
```

### 5. Route the subdomain

Add `invidious.neoprax.is` → `http://<9000-ip>:3000` on LXC 8006, immediately **before**
the trailing `- service: http_status:404`. Follow
[`docs/runbooks/add-tunnel-route.md`](../../docs/runbooks/add-tunnel-route.md) — that
file is a shared chokepoint, don't hand-edit it without reading the runbook first.

`<9000-ip>` is the address from step 1. Existing routes use LAN addresses directly
(e.g. Scribe is `http://192.168.1.170:3000`), which is why the compose publishes port
3000 on all interfaces rather than loopback.

The companion needs `/companion` on the same hostname to reach it; the compose sets
`public_url` accordingly. If video playback fails while page loads work, that path is
the first thing to check.

### 6. Cloudflare Access

Add an Access application for `invidious.neoprax.is` with the same email-PIN policy as
the other subdomains. Do this **before** the route goes live — an unauthenticated
Invidious instance will get found and hammered.

## Operations

```bash
PVE=pve
# logs
ssh $PVE 'pct exec 9000 -- bash -c "cd /opt/invidious && docker compose logs -f --tail=100"'
# restart
ssh $PVE 'pct exec 9000 -- bash -c "cd /opt/invidious && docker compose restart"'
# update (Invidious ships frequently; YouTube breakage is usually fixed upstream fast)
ssh $PVE 'pct exec 9000 -- bash -c "cd /opt/invidious && docker compose pull && docker compose up -d"'
```

### When videos stop playing

Almost always an upstream YouTube change, not a local misconfiguration. In order:

1. `docker compose pull && docker compose up -d` — the fix is usually already released.
2. Check the companion logs specifically; it does the video stream fetching, so it
   breaks before Invidious proper does.
3. Check [iv-org/invidious issues](https://github.com/iv-org/invidious/issues) for an
   open report matching the symptom.

### Backup

The Postgres volume holds only subscriptions, watch history, and preferences — small,
and re-creatable if you're willing to lose the subscription list. A Proxmox vzdump of
the container covers it:

```bash
ssh $PVE 'vzdump 9000 --mode snapshot --compress zstd --storage local'
```

## Files here

| File | Purpose |
|---|---|
| `docker-compose.yml` | The stack — pushed to `/opt/invidious/docker-compose.yml` |
| `.env.example` | Placeholder secrets; real `.env` is generated in-container and never committed |
