# 2283 — immich

Photo library and phone auto-backup. Immich v2 (docker compose), first set up Nov 2025,
abandoned when postgres filled the disk, revived 2026-09-28.

## Envelope

- Unprivileged LXC, Ubuntu, `nesting=1`, 20 cores / 12 G RAM / 12 G swap, rootfs
  `local-lvm` 88 G, `onboot: 1`, DHCP (`192.168.1.177` at time of writing — wants a
  router reservation before anything external pins it).
- `mp0: /proxpool/data/Media/Pictures/Photos,mp=/mnt/Photos` — the curated photo
  collection, mounted for use as an **external library**. Not read-only at the LXC
  level; treat it as read-only. The collection belongs to `personal-ops` curation.
- `lxc.idmap` (added 2026-09-28, same pattern as 9999): container uid 1000 → host 1000,
  container gid 1000 → host 1100 (`mediashare`), everything else shifted to 100000+.
  Requires `root:1000:1` in `/etc/subuid` and `root:1100:1` in `/etc/subgid` (already
  present on the host). Without this, immich (which runs as `1000:1000` in compose)
  cannot write the pool — that was one of the three faults that killed the first
  install.

## Interior

- Compose project at `/root/docker-compose.yml` + `/root/.env` (no secrets beyond the
  local DB password; never commit the real `.env`).
- `UPLOAD_LOCATION=/mnt/Photos/immich-uploads` — phone uploads land **on the pool**,
  inside `Media/Pictures`, so they are restic-covered. Dir is `1000:1100` mode 0775.
- `DB_DATA_LOCATION=./postgres` — postgres data on the container rootfs (NVMe), never
  the pool. Correct placement; keep it there.
- Four services: `immich_server` (:2283), `immich_machine_learning`, `immich_postgres`,
  `immich_redis`.
- Docker boot race fixed 2026-09-28: dockerd used to lose the boot race against
  networking and stay down (that is why immich was dead from the 2026-09-13 host reboot
  until 2026-09-28). Drop-in at
  `/etc/systemd/system/docker.service.d/boot-race.conf`:
  `StartLimitIntervalSec=0`, `Restart=always`, `RestartSec=10`.

## History — why the first install died

Nov 3 2025: external-library scan of ~70k assets completed, then postgres hit
*"could not extend file: No space left on device"*. The DB had bloated to 74 G
(69 G in one database) against an 88 G rootfs — likely months of unattended
crash-loop churn on top of a heavy initial import. With the disk at 100 % the stack
could not recover, and the project stalled there, undocumented.

2026-09-28: postgres dir deleted with the owner's explicit approval (it held only the
regenerable library index — `immich-uploads` did not exist yet, so no uploaded
originals were in play) and the stack brought up fresh: immich v2.2.2.
**If the DB balloons again, find the cause before growing the disk** — 70k assets do
not justify 74 G.

## Operations

- Status: `ssh pve "pct exec 2283 -- docker ps"`
- Logs: `ssh pve "pct exec 2283 -- docker logs immich_server --tail 50"`
- Update: bump `IMMICH_VERSION` in `/root/.env` (check immich release notes for
  breaking changes first), then `docker compose pull && docker compose up -d`.
- Web UI: `http://192.168.1.177:2283`, reachable from the tailnet via the approved
  `192.168.1.0/24` subnet route.
- Phone: Immich mobile app → server `http://192.168.1.177:2283` → enable auto backup.

## Restore

Recreate the LXC (envelope above, **including the idmap lines** in
`/etc/pve/lxc/2283.conf` and the `mp0` bind-mount), install docker, copy
`docker-compose.yml` + `.env`, `docker compose up -d`. Uploaded originals are on the
pool under `Media/Pictures/Photos/immich-uploads` (restic-covered); the DB is
regenerable except for album/person/user curation — if that curation ever becomes
valuable, start dumping the DB (`pg_dumpall`) to somewhere backed up.
