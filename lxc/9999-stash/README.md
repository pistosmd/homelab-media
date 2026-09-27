# LXC 9999 — stash

Media organizer (scene/performer/tag metadata over a video library). Built 2026-09-05.

| | |
|---|---|
| **IP** | `192.168.1.108` (DHCP — **router reservation still to be set**) |
| **LAN** | `http://192.168.1.108:9999` |
| **Public** | **None, deliberately.** Not routed through the tunnel. |
| **Template** | `debian-13-standard`, unprivileged, `nesting=1`, `onboot=1` |
| **Resources** | 4 cores, 2 GB RAM, 512 MB swap, 20 GB rootfs on `local-lvm` |
| **Bulk data** | `mp0: /proxpool/data/Media/_stash → /mnt/stash-data`, **writable** |
| **Library** | `mp1: /proxpool/data/Media/Stash → /mnt/library`, **writable**. Contains the clinical tree — see below |
| **Package** | `stash-linux` v0.31.1 static binary, sha1-verified against `CHECKSUMS_SHA1` |
| **Unit** | `stash`, user `stash` (uid 1000 → host 101000) |

The VMID matches Stash's default port, the same mnemonic as `9533`/`4533`.

## Why a new container rather than an existing one

All three plausible hosts were wrong:

- **`9696 mediarr`** — its services share Gluetun's network namespace, so the web UI would
  sit behind ProtonVPN and every gluetun restart would force a restart here too. That
  container already has the most fragile netns arrangement on the host; it does not need a
  fourth dependent.
- **`8096 jellyfin`** — privileged, holds `nvidia0`, and is publicly exposed at
  `studium.neoprax.is`. A second service there is a second thing running privileged.
- **`8083 library`** — already runs three services and belongs to `books@homelab`.

## The clinical library: three permissions, granted separately

**This is the most important section in this file.**

`/mnt/library/Medical_Videos` — host `/proxpool/data/Media/Stash/Medical_Videos` — is 1.5 TB
and 62,600 files of clinical video, moved here from `Media/Medical_Videos` on 2026-09-05 at
the owner's instruction. An empty stub remains at `Media/Videos/Medical_Videos`.

| | Status |
|---|---|
| Scan / index | **Authorized** 2026-09-05, index-only |
| Generate previews, sprites, covers, thumbnails, phashes | **Not authorized** |
| Read the resulting index — scene records, titles, paths, counts | **Ask the owner first** |

**Do not collapse these into one permission.** The owner authorized the scan and withheld
the reading of its output in the same instruction. Building an index is not licence to query
it. Job telemetry — `jobQueue{id status progress}`, systemd state, DB file size, whether
derived files exist — is operational and has been treated as fair game; `findScenes` and
anything like it has not.

**Note what the move cost.** The original design leaned on the bind mount: a path the
container cannot reach cannot be scanned, whatever the app is later told to do. Moving this
content *into* the library spent that guard. Everything protecting it now is config-level —
one edit, or one click in a UI with no login on it — so treat these settings as load-bearing
rather than as defence-in-depth.

The authorized scan was issued with every generation flag off:

```graphql
metadataScan(input: {
  paths: ["/mnt/library"], rescan: false,
  scanGenerateCovers: false, scanGeneratePreviews: false,
  scanGenerateImagePreviews: false, scanGenerateSprites: false,
  scanGeneratePhashes: false, scanGenerateImagePhashes: false,
  scanGenerateThumbnails: false, scanGenerateClipPreviews: false })
```

plus `write_image_thumbnails: false` in `config.yml`. Verified during the run: zero files
under `/mnt/stash-data`, and zero files in the library modified — the scan is read-only with
respect to the media.

`Medisiina/` and `Duodecim/` under `Media/Documents/` remain excluded in `config.yml`. Those
exclusions stay.

## The storage split, and why it is not negotiable

**Config and the SQLite database are on the rootfs (NVMe). The bulk generated content is
on the pool.** They are separated because the two have different failure modes, not for
capacity reasons.

```
/var/lib/stash/stash-go.sqlite   ← rootfs, local-lvm
/var/lib/stash/config.yml        ← rootfs
/var/cache/stash                 ← rootfs (ephemeral transcode scratch)
/mnt/stash-data/generated        ← pool (sprites, scrubbers, preview clips, thumbnails)
/mnt/stash-data/blobs            ← pool (covers, performer images)
```

Verified at build time that `stash-go.sqlite-shm` and `-wal` exist on `/`: this database
runs in WAL mode, which `mmap`s the `-shm` file. An `mmap` page fault against an
unreachable NFS server sleeps uninterruptibly and survives `SIGKILL` — that is what hung
digiKam on 2026-08-05 and forced a power-off. **Never move `database:` in `config.yml`
onto a `/mnt/stash-data` path.**

**Stash rewrites `config.yml` on every start and strips every comment**, so warnings
cannot live in that file — an early version of this runbook claimed they did. They live
in `/var/lib/stash/WARNINGS.md` and in `/etc/motd`, neither of which the app touches.

Generated content is plain sequential file I/O with no `mmap`, so the pool is the right
place for it — it grows to tens of GB and does not belong on a 20 GB rootfs.

## No GPU, deliberately

Preview and sprite generation runs on **CPU ffmpeg**. Both host GPUs are already spoken
for — `nvidia0` is Jellyfin's NVENC, `nvidia1` is chatterbox — and per the 2026-08-30
changelog entry nothing enforces that split but the two container configs. Claiming a
third slot is a decision that needs making explicitly, not as a side effect of this build.

The unit therefore runs the batch out of everyone's way:

```
Nice=10
IOSchedulingClass=idle
CPUWeight=50
```

`parallel_tasks: 2` in `config.yml` for the same reason. Initial generation over a large
library will take hours; that is the accepted cost of not contending for a GPU.

## Not routed through the tunnel

Same call as `4123 chatterbox`. The container is reachable on the LAN and nowhere else.
**If it is ever routed, it needs Cloudflare Access in front of it first, not after** — and
unlike `auditio` (Navidrome), there is no mobile-client PIN-flow problem to argue against
Access here, so there is no reason to expose it bare.

## Upgrading

Single static binary, so upgrades are a download, a checksum, and a restart. Note the
release publishes **SHA1**, not SHA256:

```bash
ssh pve 'pct exec 9999 -- bash -lc "
set -e
VER=<new>
cd /tmp
curl -sSLO https://github.com/stashapp/stash/releases/download/v\${VER}/stash-linux
curl -sSLO https://github.com/stashapp/stash/releases/download/v\${VER}/CHECKSUMS_SHA1
grep \"stash-linux\$\" CHECKSUMS_SHA1 | sha1sum -c -
systemctl stop stash
install -m 0755 /tmp/stash-linux /usr/local/bin/stash
systemctl start stash
"'
```

Verify the checksum rather than trusting the URL. The Navidrome build hit a checksum that
failed for the wrong reason (asset renamed, comparison run against an empty file) — a loud
wrong failure is recoverable, a skipped check is not.

## The writable-mount trap — read before changing any mount

**"The unprivileged container can write to the pool" and "the human can use their own files"
are in direct conflict.** The container must own files as host uid `101000`; the human is
host uid `1000`. There is no mode that satisfies both without an idmap.

This bit on 2026-09-05: `Media/Stash/` was created `101000:101000` mode `750` and the whole
62,600-file tree `chown`ed to `101000`, which made `/mnt/proxpool/Media/Stash/` untraversable
from the workstation. The human lost access to 1.5 TB of their own library. Restored with
`chown -R 1000:1100` + `chmod 775`, matching every sibling under `Media/`.

`9533 navidrome` never hits this because its mount is `ro=1` and it leaves ownership alone.

**The fix is an idmap, applied 2026-09-05**, mapping container uid 1000 to host uid 1000 so
the service *is* the human as far as the filesystem is concerned — not a `chown` into the
mapped range. In `/etc/pve/lxc/9999.conf`:

```
lxc.idmap: u 0 100000 1000        # container 0-999    -> host 100000-100999
lxc.idmap: g 0 100000 1000
lxc.idmap: u 1000 1000 1          # container 1000      -> host 1000   (the human)
lxc.idmap: g 1000 1100 1          # container gid 1000  -> host 1100   (mediashare)
lxc.idmap: u 1001 101001 64535    # container 1001+     -> host 101001+
lxc.idmap: g 1001 101001 64535
```

The ranges must cover all 65536 ids contiguously, and the host needs matching delegations in
`/etc/subuid` (`root:1000:1`) and `/etc/subgid` (`root:1100:1`) or `pct start` refuses.

**Changing the idmap orphans the container's own rootfs files.** Files owned by container uid
1000 were host `101000` under the old map; under the new one host `101000` means container
`1001`, so Stash would lose its own database. They must be remapped while the container is
stopped:

```bash
pct stop 9999
pct mount 9999
find /var/lib/lxc/9999/rootfs -uid 101000 -exec chown -h 1000 {} +
pct unmount 9999
```

Also `chown -R 1000:1100` the `mp0` target (`Media/_stash`), for the same reason. `mp1`
(`Media/Stash`) already had the right ownership — that was the point.

Result, verified after a reboot: Stash reads and writes both mounts, the human keeps normal
ownership, and the 590 previously unreadable files and 1 untraversable directory are down to
zero. Note the container's `stash` group is gid **991**, not 1000, so it is unaffected by the
gid line; `stat` inside the container shows group `mediashare` via a locally added gid 1000.

The tree carries mixed legacy modes — 47,399 files at `666`, 13,455 at `644`, 1,137 at `776`,
590 at `722`. Do not assume uniform permissions.

## Open items

1. ~~No credentials are set.~~ **Closed 2026-09-26** — a login was set in Settings → Security.
   Verified: an unauthenticated `GET /` now returns `302` to the login page rather than `200`.
   This mattered more than it looked: the app fronts a 1.5 TB clinical library, and by then
   the host had joined a tailnet with `192.168.1.0/24` routed, so "LAN-only" no longer meant
   "in the house".
2. **DHCP reservation** for `192.168.1.108` is not yet set on the router.
3. **`Media/Videos/Medical_Videos` is an empty stub** left behind in `videos@homelab`'s
   subtree. Harmless, but it is a name that now means nothing and will mislead someone.
   Removing it belongs to that session, not this one.
4. **Generation has never been run and is not authorized.** The index exists; no previews,
   sprites, covers or thumbnails do. Turning generation on is a separate ask — days of CPU
   ffmpeg, and it writes derived copies of clinical video onto the pool.
