# LXC 9533 — navidrome

Subsonic-compatible music server. Built 2026-08-24 because Jellyfin serves music as an
afterthought and the good mobile clients speak Subsonic, not Jellyfin.

| | |
|---|---|
| **IP** | `192.168.1.111` |
| **Public** | `https://auditio.neoprax.is` (Cloudflare tunnel, ingress rule #7) |
| **LAN** | `http://192.168.1.111:4533` |
| **Template** | `debian-13-standard`, unprivileged, `nesting=1`, `onboot=1` |
| **Resources** | 2 cores, 1 GB RAM, 512 MB swap, 8 GB rootfs on `local-lvm` |
| **Music** | `mp0: /proxpool/data/Media/Music → /mnt/music`, **`ro=1`** |
| **Package** | official `.deb` from the GitHub release, sha256-verified against `navidrome_checksums.txt` |

## The two constraints this container exists to respect

**1. The SQLite index is on the rootfs — NVMe — never on the pool.**

`DataFolder = /var/lib/navidrome`, which is `local-lvm`. Navidrome keeps a SQLite index over
the library, and SQLite in WAL mode needs an `mmap`'d `-shm` file. An `mmap` page fault
against an unreachable NFS server sleeps uninterruptibly and survives `SIGKILL` — that is
what hung digiKam on 2026-08-05 and forced a power-off. This container is exactly the
workload the *no SQLite on the pool* rule was written for: a database over a large
collection. **Collection on the pool, index on local disk.**

**2. The music mount is read-only.**

`ro=1`, verified by attempting a write (`Read-only file system`). Navidrome reads audio; it
has no business modifying the library. `Media/Music/` belongs to `music@homelab`, and a
server process is not that session.

## Config choices

- **`MusicFolder = /mnt/music`** — the whole subtree, not just `MusicLibrary/`. Measured at
  build time: `MusicLibrary/` is the real beets library (5000+ files, scan capped there),
  `Lidarr/` holds **134 audio files** despite being recorded elsewhere as an unused pipeline,
  and `AudacityArchive/` holds **no audio at all** — so including it costs one directory walk
  and nothing else.
- **`ScanSchedule = @every 24h`** rather than filesystem watching. The library is on spinning
  disks behind a bind mount; inotify across that is not worth the wake-ups for a collection
  that changes only when someone deliberately curates it.
- **`EnableTranscodingConfig = false`** — clients that handle FLAC should get FLAC, and 2
  cores are shared with everything else on the host.

## No Cloudflare Access on this route, deliberately

`auditio.neoprax.is` is plain HTTP to the origin, the same shape as `studium` (Jellyfin).
**Access uses a browser PIN flow that music clients cannot complete**, so putting it in front
would make the mobile apps — the entire point — stop working. Navidrome's own login is the
gate. That means a real password on the admin account, and it means the login page is on the
public internet: create the admin account immediately after first exposing the host, because
until you do, the setup page is what is reachable.

## Mobile clients

**Symfonium** (Android, paid) is the one people settle on. Free: **substreamer**, **Tempo**.
iOS: **play:Sub**, **Amperfy**. Point any of them at `https://auditio.neoprax.is`, no port.

## Upgrading

The `.deb` brings its own systemd unit, so upgrades are ordinary:

```bash
ssh pve 'pct exec 9533 -- bash -lc "
cd /tmp && VER=<new>; DEB=navidrome_${VER}_linux_amd64.deb
curl -sSLO https://github.com/navidrome/navidrome/releases/download/v${VER}/${DEB}
curl -sSLO https://github.com/navidrome/navidrome/releases/download/v${VER}/navidrome_checksums.txt
grep \"${DEB}\$\" navidrome_checksums.txt | sha256sum -c - && apt-get install -y ./${DEB}
"'
```

**Verify the checksum, do not skip it.** The first install attempt reported a mismatch — the
cause was the asset being named `navidrome_checksums.txt` rather than `checksums.txt`, so the
comparison ran against an empty file. A check that fails loudly for the wrong reason is
recoverable; trusting the URL is not.
