# 2284 — syncthing

Raw file-level phone photo backup channel, complementing Immich (2283): Syncthing on
the phone pushes the camera folder here continuously; Immich provides the browsable
timeline. Created 2026-09-28.

## Envelope

- Unprivileged Debian 13 LXC, 1 core / 1 G RAM / 512 M swap, rootfs `local-lvm` 8 G,
  `onboot: 1`, static IP `192.168.1.30/24` gw `.1` (deliberately static and below the
  DHCP pool — the phone pins this address, and the `.251`/1020 lesson says never hang
  a client config off a lease).
- `mp0: /proxpool/data/Media/Pictures/PhoneSync,mp=/data` — the receive folder.
  `1000:1100` mode 0775 on the host; inside `Media/Pictures`, so **restic-covered**.
- `lxc.idmap` same pattern as 9999/2283: container uid 1000 → host 1000, gid 1000 →
  host 1100. Files written by syncthing land on the pool as `borgbackup:mediashare`.

## Interior

- Debian-packaged syncthing (v1.29.x), unit `syncthing@syncthing.service`, running as
  user `syncthing` (uid 1000, gid 1000 — note the group is named `sync`; the username
  `sync` is reserved by base Debian, hence the longer name).
- Config + index on the rootfs at `~syncthing/.local/state/syncthing/` — **never the
  pool** (SQLite/LevelDB rule).
- One folder: id `0aahi-kqe3v` (the phone's auto-generated ID, label "Pixel Camera"), path `/data`, type **receiveonly**. The default
  `~/Sync` folder was deleted.
- Hardening: global announce **off**, relays **off**, NAT traversal **off**. The
  instance is reachable only on LAN/tailnet (`tcp://192.168.1.30:22000`); nothing is
  announced to public Syncthing infrastructure.
- GUI bound to `127.0.0.1:8384` only, no password set (loopback implies root-on-host).
  Administer via CLI: `pct exec 2284 -- runuser -u syncthing -- syncthing cli ...`

## Device ID

Server device ID (public, needed on the phone to pair):

```
6L53OZF-ZLZA56I-6SXFPSV-3ORHWRG-FOSDUSM-IADGQCD-2MQ6VCS-ECCKPAA
```

## Pairing the phone (one-time)

1. Phone: install **Syncthing-Fork** (Catfriend1, F-Droid) — the official app is
   discontinued.
2. Phone: add remote device with the ID above; set its address explicitly to
   `tcp://192.168.1.30:22000` (no discovery is running); share the camera folder
   (DCIM) with it as **send only**. Set run conditions (e.g. charger + any network —
   traffic rides the tailnet off-LAN).
3. Server: accept the phone by adding its device ID and sharing the folder back:

   ```
   pct exec 2284 -- runuser -u syncthing -- syncthing cli config devices add --device-id <PHONE-ID> --name phone
   pct exec 2284 -- runuser -u syncthing -- syncthing cli config folders 0aahi-kqe3v devices add --device-id <PHONE-ID>
   ```

## Semantics — backup-shaped, deliberately

Receive-only means the server never pushes changes back to the phone, and
**`ignore-delete` is ON** (owner's decision, 2026-09-28): deleting a photo on the phone
does NOT delete the archived copy here. "Clear phone, keep archive" is the intended
workflow. Consequence: the server's copy is authoritative once synced, and the folder
will show remote "out of sync" deletions on the phone side — that is normal. PhoneSync is a
staging area: curation into `Photos/YYYY/MM/DD` remains a human/digiKam step.

## Restore

Recreate envelope (idmap lines + mp0), `apt install syncthing`, recreate user
`syncthing` uid 1000, re-add folder + phone device per above. The data is the pool
directory; the index rebuilds on first scan.
