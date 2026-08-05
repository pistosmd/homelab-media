# homelab-media

Personal self-hosted media and photo stack running on the Neopraxis Proxmox host —
Jellyfin, Immich, Calibre-Web, Audiobookshelf, the arr stack, WebODM, and a planned
Invidious.

This is the **personal** half of a split. Neopraxis production infrastructure — the
Scribe clinical app, TVR, and the shared Cloudflare tunnel — lives in
[`lv-neopraxis/homelab`](https://github.com/lv-neopraxis/homelab). Both repos describe
containers on one host; the split is about which account owns the record.

## Layout

```
homelab-media/
├── CLAUDE.md                  # inventory, storage, working rules — read this first
└── lxc/
    └── 9000-invidious/        # one directory per container
        ├── docker-compose.yml
        ├── .env.example
        └── README.md          # provisioning + operations
```

## Conventions

- One directory per container, named `<id>-<name>`.
- Secrets never committed — `.env.example` with placeholders only.
- The host is the source of truth; this repo is the record. Verify with `pct list`
  before trusting a table here.
- Container IDs are shared across both repos — check both inventories before claiming one.

Host access, the tunnel, and the multi-chat ownership rules are canonical in the
Neopraxis repo and are referenced rather than duplicated. See [CLAUDE.md](CLAUDE.md).
