# Yggdrasil Homelab

A NixOS homelab on Proxmox VE, built so that **any single archive can rebuild the whole thing** — from a surviving VM, or from nothing on a freshly installed Proxmox.

Each host is a NixOS configuration. One flake turns it into:

- a **template** — a rootfs tarball of the whole VM (Nix closure, kernel, a ready-made EFI System Partition);
- a **kit** — the sources alone (this repository's files, with secrets encrypted), which every VM also carries as `/etc/nixos`;
- a small script that turns the template into a bootable **qcow2** on a plain Proxmox host — no Nix needed there.

Terraform creates the VMs from those images; after that, VMs are updated in place with `nixos-rebuild switch`. **Yggdrasil**, a separate LXC template, is the root everything can be rebuilt from.

```
hosts/<host>.nix ─nix build─▶ template ─▶ NAS ─▶ mk-qcow2.sh on Proxmox ─▶ qcow2 ─▶ terraform ─▶ VM
                                                   ▲ host age key, via stdin       nixos-rebuild switch ─┘
```

## Layout

| Path | What it is |
|---|---|
| `flake.nix` | hosts, packages (`<host>-template`, `<host>-kit`, `<host>-mk-qcow2`, `yggdrasil-template`), dev shell |
| `hosts/` | one file per VM; `hosts/_parked/` is ignored by the flake |
| `operator/yggdrasil.nix` | the root LXC (Proxmox `pct create`-able) |
| `modules/` | `kit` (the `/etc/nixos` kit + operator tools), `template` (VM image, ESP, first-boot registration), `sops`, `proxmox` (hardware/boot), `heimdall` (network, firewall, Tailscale), `bifrost` (users, SSH) |
| `share/services/<name>/default.nix` | a service as a NixOS module, with optional seed data copied once on first boot |
| `share/terraform/` | Proxmox VMs (bpg/proxmox), credentials read from sops at run time |
| `share/secrets/` | sops-encrypted secrets; rules in `.sops.yaml` |
| `share/scripts/mk-qcow2.sh` | template → qcow2, plain bash |
| `bootstrap.py` | drives everything |
| `site.example.json` | this installation's addresses and hosts — copy to `site.json` |

## Using it

You need Nix with flakes on an x86_64-linux machine, and a Proxmox VE host reachable over SSH.

1. `cp site.example.json site.json` and fill in your network, Proxmox host, NAS and SSH key.
2. Create your own age keys (an admin key, one per host), put **your** public keys in `.sops.yaml`, and recreate the files in `share/secrets/` with `sops` — the ones here are encrypted for the author's keys only.
3. Then:

```bash
python3 bootstrap.py --host nidavellir build --image   # template + kit → NAS, qcow2 → Proxmox
python3 bootstrap.py --host nidavellir init --apply    # terraform (shows the plan, asks first)
python3 bootstrap.py --host nidavellir switch          # later changes, applied in place
python3 bootstrap.py --host yggdrasil build            # the root LXC template
```

`bootstrap.py` enters `nix develop` on its own when `sops` isn't installed. Terraform state is kept on the Proxmox host (`/root/homelab/`), never locally — it holds decrypted secrets.

## Design notes

- **Secrets never become Nix paths.** A file referenced as `./secret` is copied into the world-readable Nix store; here every secret is a sops-nix runtime path. Each host's age key is written into its disk image as the image is created, from sops, through stdin.
- **Config is a symlink, data is a copy.** `/etc/nixos` points into the store and follows every switch; service data is copied once and then belongs to the service.
- **An image is only how a VM is born.** Terraform ignores later image changes, so a new image never recreates a VM (and its data).
- **Reproducible.** Archive names carry a content hash; the same config gives the same file, wherever it is built.

## License

MIT — see `LICENSE`. Built by Petrickah, with Claude Code as a pair; commit trailers say who wrote what.
