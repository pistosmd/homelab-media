# homelab-media — CLAUDE.md

Personal self-hosted media and photo stack on the Neopraxis Proxmox host. Container
inventory, provisioning runbooks, and service configs for the containers that are
**mine**, not Neopraxis's.

**This repo is the personal half of a deliberate split.** The Neopraxis production
containers — Scribe (8011), TVR (8020), the Claude Code sandbox (8010) — and the shared
Cloudflare tunnel live in [`lv-neopraxis/homelab`](https://github.com/lv-neopraxis/homelab),
checked out at `~/Documents/github/homelab/`. Nothing clinical belongs here.

Both repos describe containers on **one** Proxmox host. The split is about ownership and
which GitHub account holds the record, not about two machines.

## Access

Same host as the Neopraxis repo. See
[`../homelab/CLAUDE.md`](../homelab/CLAUDE.md#access) for SSH aliases, multiplexing, and
the off-LAN path — that file is canonical for host access and is not duplicated here.

Short version: `ssh pve` on LAN, `ssh pve-remote` off-LAN, `ssh pve 'pct exec <id> -- <cmd>'`
for a container shell.

## LXC inventory — media and personal

Verified against `pct list` on 2026-08-05. **Re-verify before relying on it** — this
table is a snapshot, the host is authoritative.

| ID | Name | Purpose | Notes |
|---|---|---|---|
| 2283 | immich | Photo library | |
| 8030 | webodm | WebODM (photogrammetry) | |
| 8083 | library | Calibre-Web ×2 + Audiobookshelf | Exposed at `lib.neoprax.is` → `:8084` |
| 8096 | jellyfin | Jellyfin | Privileged, NVIDIA RTX 3060 Ti passthrough. Exposed at `studium.neoprax.is` |
| 9696 | mediarr | arr stack + qBittorrent | Behind Gluetun/ProtonVPN |
| 9000 | invidious | YouTube frontend | **Planned** — see `lxc/9000-invidious/` |

ID convention (shared with the Neopraxis repo, so IDs never collide): `8xxx` for
services, `9xxx` for media. Pick an unused ID and record it here in the same commit that
adds the container's directory. **Check both repos' tables before claiming an ID.**

## Storage

The media library lives on `/mnt/proxpool/`, which reaches the host pool
`/proxpool/data` over **two transports**: NFS4 automount on the LAN
(`192.168.1.16:/proxpool/data`, the `fstab` entry) and sshfs over
`root@ssh.neoprax.is:/proxpool/data` off-LAN. `mount-proxpool` picks one by pinging the
LAN address. autofs and sshfs fight over the mountpoint, so plain `umount` reverts on any
path access — use `unmount-proxpool --detach`. Off-LAN you are moving bytes through the
Cloudflare tunnel; don't start a large media job there without meaning to.

**One subtree is not yours.** `/mnt/proxpool/Media/Documents/Medisiina/` holds the
clinical reference corpora, bind-mounted read-only into LXC 8011. It belongs to
`scribe-leader` and is written only by `scribe-app/scripts/deploy.sh --corpus`. A
hand-edit there lands in the clinician's live app with no verification and no rollback.
Everything else under the pool is `personal-ops`'.

`/mnt/proxpool/Media/Music/` is served by Jellyfin and managed with Strawberry; the real
content is under the relocated beets `MusicLibrary/`. The Lidarr/Nicotine pipeline exists
but was never used and is empty by intent.

## Ingress

Media services are exposed through the **shared** Cloudflare tunnel on LXC 8006, whose
config is owned by the Neopraxis repo because it also fronts the clinical app. Media
routes currently live: `studium.neoprax.is` (Jellyfin), `lib.neoprax.is` (Calibre-Web).

**Adding or changing a media route is not a change you make here.** The config is
single-writer — see [`../homelab/docs/runbooks/add-tunnel-route.md`](../homelab/docs/runbooks/add-tunnel-route.md)
and relay the request. Editing `/etc/cloudflared/config.yml` directly from this repo's
context risks dropping a route that Scribe depends on.

## Working rules

1. **The host is the source of truth, this repo is the record.** Verify with `pct list` /
   `pct config` before trusting a table here. When they disagree, fix the repo.
2. **Never `pct destroy`, `pct stop`, snapshot or resize a running container without
   asking** — and never touch a container this repo doesn't list. 8011 in particular is
   the clinician's live documentation app on 4GB with no swap; a media transcode or
   backup that starves the host is a clinical incident, not a failed experiment.
3. **Secrets never land in this repo.** Commit `.env.example` with placeholder values;
   real `.env` files live only inside their container. `.gitignore` enforces this, but
   check anyway. ProtonVPN and Cloudflare credentials especially.
4. **One container per directory** under `lxc/<id>-<name>/`, holding its compose file,
   `.env.example`, and a `README.md` covering provisioning + restore.
5. **FOSS and privacy-respecting by default** — no Google/Meta/Amazon services where
   there's an alternative.

## Ownership and the other chats

This host is reached by several Claude Code chats at once. The roster, the
envelope/interior boundary, and the single-writer table are canonical in
[`../homelab/docs/INSTANCES.md`](../homelab/docs/INSTANCES.md) — **read it before your
first host action**, it is not duplicated here.

The short version for work in this repo: you are acting as `personal-ops`. You own the
media containers' interiors and `/mnt/proxpool` — except `Media/Documents/Medisiina/`,
see Storage above. You do **not** own the container
envelope (`pct`), the tunnel config, or `~/.ssh/config`. Record every host mutation in
[`../homelab/docs/CHANGELOG.md`](../homelab/docs/CHANGELOG.md) — one host, one changelog,
and it lives in the Neopraxis repo because that is where the host-level docs are.

## Related repos

| Repo | What |
|---|---|
| `lv-neopraxis/homelab` | Neopraxis production infra: 8006 tunnel, 8010, 8011 Scribe, 8020 TVR, 8787. Canonical for host access + the instance roster. |
| `lv-neopraxis/scribe-app` | Scribe clinical documentation app (deploys to 8011) |
| `lv-neopraxis/tvr-app` | TVR voice chat (deploys to 8020) |
