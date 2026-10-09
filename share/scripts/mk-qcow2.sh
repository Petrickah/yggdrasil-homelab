#!/usr/bin/env bash
# Turn a NixOS rootfs template (vztmpl-nixos-<host>-*.tar.zst) into a bootable
# qcow2 on a plain Proxmox host — no Nix needed there. This file is the source;
# `nix build .#<host>-mk-qcow2` fills in the labels and size from that host's
# config, so they always match its fileSystems declarations.
#
# Usage: mk-qcow2.sh <template.tar.zst> <output.qcow2> [--age-key-stdin]
#   --age-key-stdin  write stdin to /var/lib/sops-nix/key.txt inside the image
set -euo pipefail

ESP_LABEL="@espLabel@"
ROOT_LABEL="@rootLabel@"
DISK_SIZE="@diskSize@"

template="$1"
output="$2"
age_key_stdin="${3:-}"

work="$(mktemp -d /var/tmp/mk-qcow2.XXXXXX)"
raw="$work/disk.raw"
root="$work/root"
esp="$work/esp"
loop=""

cleanup() {
  mountpoint -q "$esp"  && umount "$esp"  || true
  mountpoint -q "$root" && umount "$root" || true
  [ -n "$loop" ] && losetup -d "$loop"    || true
  rm -rf "$work"
}
trap cleanup EXIT

# 1. Partition a raw disk: 512M ESP + root filling the rest
truncate -s "$DISK_SIZE" "$raw"
sgdisk --zap-all \
  -n1:1M:+512M -t1:EF00 -c1:"$ESP_LABEL" \
  -n2:0:0      -t2:8300 -c2:"$ROOT_LABEL" \
  "$raw"

loop="$(losetup --find --partscan --show "$raw")"
udevadm settle || true
mkfs.vfat -F 32 -n "$ESP_LABEL" "${loop}p1"
mkfs.ext4 -q -L "$ROOT_LABEL" "${loop}p2"

# 2. Unpack the template onto root, then move /boot onto the ESP
mkdir -p "$root" "$esp"
mount "${loop}p2" "$root"
mount "${loop}p1" "$esp"

tar --zstd -xpf "$template" -C "$root" --numeric-owner
cp -r "$root/boot/." "$esp/"
rm -rf "$root/boot"
mkdir "$root/boot"

# 3. The host's sops-nix age key, so its secrets decrypt on first boot
if [ "$age_key_stdin" = "--age-key-stdin" ]; then
  install -D -m 600 /dev/stdin "$root/var/lib/sops-nix/key.txt"
fi

umount "$esp" "$root"
losetup -d "$loop"
loop=""

# 4. Convert to qcow2 where Proxmox can import it
mkdir -p "$(dirname "$output")"
qemu-img convert -f raw -O qcow2 "$raw" "$output"
sha256sum "$output"
