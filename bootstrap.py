#!/usr/bin/env python3
"""Bootstrap pipeline orchestrator for NixOS homelab VMs.

Runs the same from the vault, from /etc/nixos on any VM (copy it somewhere
writable first) or from an extracted homelab-kit-*.tar.zst. All it needs is
Nix and the sops admin age key (~/.config/sops/age/keys.txt).

  build   [--image]           template + kit → NAS; --image also makes the qcow2
                              (--host yggdrasil: the root LXC template, for `pct create`)
  init    [--apply|--destroy] terraform, with its state kept on the Proxmox host
  switch                      build here, copy over SSH, activate on the running VM
  seed    <service>           copy share/services/<service>/data to the VM, once
  clean   [--archives] [--images] [--store] [--all]
  create  | backup | restore [--from <file>]   (--host yggdrasil only)
                              the root LXC is never Terraform's: created here,
                              backed up here, removed only by hand in Proxmox
  rotate  console-password | admin-passphrase | admin-key | host-key |
          proxmox-token | ssh-key | secret <file> <key>
"""

import argparse
import atexit
import getpass
import hashlib
import json
import os
import shutil
import subprocess
import sys
import ssl
import tempfile
import urllib.request

from datetime import datetime
from pathlib import Path

# ── Configuration ──────────────────────────────────────────────────────────
REPO_ROOT = Path(__file__).resolve().parent          # 10_Homelab/ or the kit

# `path:` makes Nix read the folder as it is on disk. Without it, inside a git
# checkout Nix would only see tracked files — and site.json, the service seeds
# and admin-key.age are gitignored on purpose, yet must still end up in the kit.
FLAKE = f"path:{REPO_ROOT}"

# Everything specific to this installation, shared with Nix and Terraform
SITE_FILE = REPO_ROOT / "site.json"
if not SITE_FILE.exists():
    sys.exit(f"✕ {SITE_FILE} not found — copy site.example.json to site.json and fill in your values.")
SITE = json.loads(SITE_FILE.read_text())

HOSTS = sorted(p.stem for p in (REPO_ROOT / "hosts").glob("*.nix"))
ROOT  = "yggdrasil"   # operator/yggdrasil.nix: the root LXC, build-only (no qcow2/terraform/switch)

TERRAFORM_DIR = REPO_ROOT / "share" / "terraform"
SECRETS_DIR   = REPO_ROOT / "share" / "secrets"
RESULTS_DIR   = REPO_ROOT / "results"

PROXMOX_HOST         = SITE["proxmox"]["host"]
PROXMOX_TEMPLATE_DIR = "/mnt/pve/syno-nfs/template/cache"  # syno-nfs = the NAS
PROXMOX_IMPORT_DIR   = "/var/lib/vz/import"                # local:import
PROXMOX_STATE_DIR    = "/root/homelab"                     # terraform state lives here
PROXMOX_BACKUP_DIR   = "/mnt/pve/syno-nfs/dump"            # vzdump on the NAS

# sops: the admin key (outside the repo) and the passphrase-protected copy in it
AGE_DIR       = Path.home() / ".config" / "sops" / "age"
ADMIN_KEY     = Path(os.environ.get("SOPS_AGE_KEY_FILE", AGE_DIR / "keys.txt"))
ADMIN_KEY_AGE = SECRETS_DIR / "admin-key.age"
SOPS_CONFIG   = REPO_ROOT / ".sops.yaml"
VM_AGE_KEY    = "/var/lib/sops-nix/key.txt"
REGISTRY_USER = "registrar"                     # your login on the registry

# What Terraform needs between runs, kept next to the Proxmox it describes
STATE_FILES = ["terraform.tfstate", "terraform.tfstate.backup", "images.auto.tfvars.json"]


# ── Helpers ────────────────────────────────────────────────────────────────

def run(args, **kwargs):
    """Print and run a command; stop at the first failure."""
    print(f"✦ {' '.join(str(a) for a in args)}")
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def sops_decrypt(file, key):
    """Decrypt one key from a sops file, in memory."""
    return subprocess.run(["sops", "--decrypt", "--extract", f'["{key}"]', str(SECRETS_DIR / file)],
                          check=True, capture_output=True, text=True).stdout


def ssh_key():
    """The Proxmox/VM SSH key, decrypted from sops into a private temp file."""
    if not hasattr(ssh_key, "path"):
        tmp = Path(tempfile.mkdtemp(prefix="homelab-ssh-"))
        atexit.register(shutil.rmtree, tmp, ignore_errors=True)
        ssh_key.path = tmp / "id_ed25519"
        ssh_key.path.touch(mode=0o600)
        ssh_key.path.write_text(sops_decrypt("terraform.yaml", "proxmox_ssh_key"))
    return ssh_key.path


def ssh_opts():
    return ["-i", ssh_key(), "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=accept-new"]


def ssh(target, cmd, **kwargs):
    return run(["ssh", *ssh_opts(), target, cmd], **kwargs)


def scp(src, dst):
    return run(["scp", *ssh_opts(), "-q", src, dst])


def remote_exists(proxmox, path):
    return subprocess.run(["ssh", *ssh_opts(), f"root@{proxmox}", f"test -e {path}"]).returncode == 0


def nix_build(host, output):
    """Build .#<host>-<output> and return the store path of the result."""
    link = RESULTS_DIR / f"{host}-{output}"
    run(["nix", "build", f"{FLAKE}#{host}-{output}", "--out-link", link], cwd=REPO_ROOT)
    return link.resolve()


def short_hash(path):
    with open(path, "rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()[:12]


def template_name(host, tarball):
    return f"vztmpl-nixos-{host}-{short_hash(tarball)}{''.join(tarball.suffixes[-2:])}"


def vm_user(host):
    """First user bifrost.nix defines for the host."""
    out = subprocess.run(["nix", "eval", "--json", f"{FLAKE}#nixosConfigurations.{host}.config.homelab.bifrost.users",
                          "--apply", "builtins.attrNames"], cwd=REPO_ROOT, check=True,
                         capture_output=True, text=True).stdout
    return json.loads(out)[0]


# ── Terraform state on the Proxmox host ────────────────────────────────────

def pull_state(proxmox):
    """Fetch the state; a Proxmox without one starts from nothing, on purpose."""
    for name in STATE_FILES:
        (TERRAFORM_DIR / name).unlink(missing_ok=True)
        if remote_exists(proxmox, f"{PROXMOX_STATE_DIR}/{name}"):
            scp(f"root@{proxmox}:{PROXMOX_STATE_DIR}/{name}", TERRAFORM_DIR / name)


def push_state(proxmox):
    """Send the state back and drop the local copy — it holds decrypted secrets."""
    ssh(f"root@{proxmox}", f"mkdir -p -m 700 {PROXMOX_STATE_DIR}")
    for name in STATE_FILES:
        local = TERRAFORM_DIR / name
        if local.exists():
            scp(local, f"root@{proxmox}:{PROXMOX_STATE_DIR}/{name}")
            local.unlink()


# ── Steps ──────────────────────────────────────────────────────────────────

def step_build(host, proxmox, build_image):
    """
        Build the template + kit and upload both to the NAS (through the
        Proxmox host's syno-nfs mount). With --image, also turn the template
        into a qcow2 in local:import and record it for Terraform.
    """
    print(f"\n═══ Build template + kit for {host} ═══")
    tarball  = next((nix_build(host, "template") / "tarball").glob("*.tar.*"))
    kit      = nix_build(host, "kit")
    template = template_name(host, tarball)
    target   = f"root@{proxmox}"

    if remote_exists(proxmox, f"{PROXMOX_TEMPLATE_DIR}/{template}"):
        print(f"✔ {template} already on the NAS.")
    else:
        scp(tarball, f"{target}:{PROXMOX_TEMPLATE_DIR}/{template}")

    # The kit is tiny: keep a hashed copy plus a stable name to download in a disaster.
    # scp keeps the store's read-only mode, and the NAS won't let root overwrite
    # that, so replace the stable name instead and make everything writable again.
    kit_hashed = f"homelab-kit-{host}-{short_hash(kit)}.tar.zst"
    scp(kit, f"{target}:{PROXMOX_TEMPLATE_DIR}/{kit_hashed}")
    ssh(target, f"cd {PROXMOX_TEMPLATE_DIR} && rm -f homelab-kit-{host}.tar.zst && "
                f"cp {kit_hashed} homelab-kit-{host}.tar.zst && "
                f"chmod 644 {template} {kit_hashed} homelab-kit-{host}.tar.zst")

    if not build_image:
        return

    print(f"\n═══ Build qcow2 image for {host} ═══")
    image = f"nixos-{host}-{short_hash(tarball)}.qcow2"
    if remote_exists(proxmox, f"{PROXMOX_IMPORT_DIR}/{image}"):
        print(f"✔ {image} already in local:import.")
    else:
        script = nix_build(host, "mk-qcow2")
        scp(script, f"{target}:/tmp/mk-qcow2-{host}.sh")
        # The host's age key goes straight from sops into the image, through stdin
        ssh(target, f"chmod +x /tmp/mk-qcow2-{host}.sh && /tmp/mk-qcow2-{host}.sh "
                    f"{PROXMOX_TEMPLATE_DIR}/{template} {PROXMOX_IMPORT_DIR}/{image} --age-key-stdin; "
                    f"status=$?; rm -f /tmp/mk-qcow2-{host}.sh; exit $status",
            input=sops_decrypt("hosts.yaml", host), text=True)

    # Record it for Terraform, next to the state it belongs with
    pull_state(proxmox)
    tfvars = TERRAFORM_DIR / "images.auto.tfvars.json"
    images = json.loads(tfvars.read_text())["images"] if tfvars.exists() else {}
    images[host] = image
    tfvars.write_text(json.dumps({"images": images}, indent=2) + "\n")
    push_state(proxmox)


def step_init(hosts, proxmox, apply, destroy, yes):
    """
        terraform init, then --apply or --destroy: one host with --host,
        everything (VMs + NAS storage + certificate) without it.
    """
    if not TERRAFORM_DIR.exists():
        sys.exit(f"✕ Terraform dir not found: {TERRAFORM_DIR}")

    run(["terraform", "init", "-input=false"], cwd=TERRAFORM_DIR)
    if not (apply or destroy):
        return

    node    = ssh(f"root@{proxmox}", "hostname", capture_output=True, text=True).stdout.strip()
    action  = "apply" if apply else "destroy"
    targets = [f"-target=module.{h}" for h in hosts] if hosts != HOSTS else []
    extra   = [f"-var=proxmox_host={proxmox}", f"-var=proxmox_node={node}"] + (["-auto-approve"] if yes else [])

    print(f"\n═══ Terraform {action} for {', '.join(hosts)} ═══")
    pull_state(proxmox)
    try:
        run(["terraform", action, *targets, *extra], cwd=TERRAFORM_DIR)
    finally:
        push_state(proxmox)


def step_switch(host, user):
    """What nixos-rebuild --target-host does, done with the local Nix.

    Not nixos-rebuild itself: it brings its own upstream Nix, which copies the
    whole `path:` flake — live service data included, ~3G — into the store on
    every run, filling the disk and starving this VM. The local Determinate Nix
    evaluates lazily and only copies what the kit actually uses."""
    print(f"\n═══ NixOS switch for {host} ═══")
    target   = f"{user or vm_user(host)}@{host}"
    toplevel = run(["nix", "build", "--no-link", "--print-out-paths",
                    f"{FLAKE}#nixosConfigurations.{host}.config.system.build.toplevel"],
                   cwd=REPO_ROOT, stdout=subprocess.PIPE, text=True).stdout.strip()

    env = dict(os.environ, NIX_SSHOPTS=" ".join(str(o) for o in ssh_opts()))
    # Built right here: the VM takes them unsigned because the user is in trusted-users
    run(["nix", "copy", "--no-check-sigs", "--to", f"ssh-ng://{target}", toplevel], env=env)

    # As a transient unit, so the activation finishes even if SSH drops midway
    ssh(target, f"sudo nix-env -p /nix/var/nix/profiles/system --set {toplevel} && "
                f"sudo systemd-run --collect --no-ask-password --pipe --quiet --service-type=exec "
                f"--unit=bootstrap-switch-to-configuration {toplevel}/bin/switch-to-configuration switch")

def step_seed(host, service, user):
    """Copy a service's data straight to the VM, once, before its first switch.

    Never through the kit: data carries secrets of its own (keys, tokens,
    private repos), and the kit lands in the world-readable store and on the
    NAS. Ownership and modes are kept as they are — after a migration that's
    what the container image expects."""
    print(f"\n═══ Seed {service} on {host} ═══")
    src = REPO_ROOT / "share" / "services" / service / "data"
    if not src.is_dir():
        sys.exit(f"✕ No {src.relative_to(REPO_ROOT)} to copy.")

    declared = json.loads(subprocess.run(
        ["nix", "eval", "--json", f"{FLAKE}#nixosConfigurations.{host}.config.homelab.services",
         "--apply", f's: s."{service}" or null'],
        cwd=REPO_ROOT, check=True, capture_output=True, text=True).stdout)
    if declared is None:
        sys.exit(f"✕ {host} doesn't declare homelab.services.{service} — import its module in hosts/{host}.nix first.")

    target = f"{user or vm_user(host)}@{host}"
    dst    = f"/var/lib/services/{service}"
    if subprocess.run(["ssh", *ssh_opts(), target, f"sudo test -e {dst}"]).returncode == 0:
        sys.exit(f"✕ {dst} already exists on {host}. seed only fills an empty spot — "
                 "remove it by hand if you really mean to replace the data.")

    # Into a temporary directory first, renamed only once everything arrived
    tmp    = f"/var/lib/services/.{service}.seed"
    chown  = f"sudo chown -R {declared['owner']} {tmp} && " if declared.get("owner") else ""
    reader = ([] if os.geteuid() == 0 else ["sudo", "-n"]) + ["tar", "-C", str(src), "--numeric-owner", "-cf", "-", "."]
    tar = subprocess.Popen(reader, stdout=subprocess.PIPE)
    ssh(target, f"sudo rm -rf {tmp} && sudo mkdir -p {tmp} && sudo tar -C {tmp} --numeric-owner -xpf - && "
                f"{chown}sudo mv {tmp} {dst}", stdin=tar.stdout)
    tar.stdout.close()
    if tar.wait() != 0:
        sys.exit("✕ Reading the local data failed.")
    size = ssh(target, f"sudo du -sh {dst}", capture_output=True, text=True).stdout.split()[0]
    print(f"✔ {service} data is on {host} ({size}). Now `switch` to start it.")


def step_clean(host, proxmox, archives, images, store):
    """Remove what build left behind, locally and on the Proxmox host/NAS."""
    target = f"root@{proxmox}"

    if archives:
        print(f"\n═══ Clean template + kit for {host} ═══")
        for output in ["template", "kit", "mk-qcow2"]:
            (RESULTS_DIR / f"{host}-{output}").unlink(missing_ok=True)
        ssh(target, f"rm -f {PROXMOX_TEMPLATE_DIR}/vztmpl-nixos-{host}-*.tar.zst "
                    f"{PROXMOX_TEMPLATE_DIR}/homelab-kit-{host}*.tar.zst")

    if images:
        # A VM keeps its own copy of the disk once imported; the qcow2 is spare
        print(f"\n═══ Clean qcow2 images for {host} ═══")
        ssh(target, f"rm -f {PROXMOX_IMPORT_DIR}/nixos-{host}-*.qcow2")

    if store:
        print(f"\n═══ Clean local Nix store ═══")
        run(["nix", "store", "gc"], cwd=REPO_ROOT)


# ── Yggdrasil, the root LXC ────────────────────────────────────────────────
# Deliberately outside Terraform: a `destroy` run from inside Yggdrasil must
# never be able to take Yggdrasil down. It's created with Proxmox's
# protection flag, so removing it means unticking Protection in the UI first.

def latest_remote(proxmox, pattern):
    """Newest file matching `pattern` on the Proxmox host, or None."""
    out = subprocess.run(["ssh", *ssh_opts(), f"root@{proxmox}", f"ls -1t {pattern} 2>/dev/null | head -1"],
                         check=True, capture_output=True, text=True).stdout.strip()
    return out or None


def guest_exists(proxmox, vmid):
    out = subprocess.run(["ssh", *ssh_opts(), f"root@{proxmox}",
                          "pvesh get /cluster/resources --type vm --output-format json"],
                         check=True, capture_output=True, text=True).stdout
    return any(r.get("vmid") == vmid for r in json.loads(out))


def require_backup_storage(proxmox):
    if subprocess.run(["ssh", *ssh_opts(), f"root@{proxmox}", "pvesm status --storage syno-nfs"],
                      capture_output=True).returncode != 0:
        nas = SITE["nas"]
        sys.exit("✕ No `syno-nfs` storage on this Proxmox yet. Add it first:\n"
                 f"  pvesm add nfs syno-nfs --server {nas['address']} --export {nas['export']} "
                 "--content vztmpl,backup,import,snippets")


def step_create_root(proxmox):
    """Create Yggdrasil from the newest template on the NAS, protected."""
    cfg, target = SITE["yggdrasil"], f"root@{proxmox}"
    print(f"\n═══ Create {ROOT} (CT {cfg['ctid']}) ═══")
    require_backup_storage(proxmox)
    if guest_exists(proxmox, cfg["ctid"]):
        sys.exit(f"✕ CT {cfg['ctid']} already exists — `restore` needs it gone, and only you remove it, by hand.")
    template = latest_remote(proxmox, f"{PROXMOX_TEMPLATE_DIR}/vztmpl-nixos-{ROOT}-*")
    if not template:
        sys.exit(f"✕ No {ROOT} template on the NAS — run `bootstrap.py --host {ROOT} build` first.")

    net = SITE["network"]
    ip  = f"ip={cfg['address']}/{net['prefixLength']},gw={net['gateway']}"
    ssh(target, f"pct create {cfg['ctid']} syno-nfs:vztmpl/{Path(template).name} "
                f"--hostname {ROOT} --ostype nixos --unprivileged 1 --features nesting=1 "
                f"--cores {cfg['cores']} --memory {cfg['memory']} --rootfs local-zfs:{cfg['disk']} "
                f"--net0 name=eth0,bridge=vmbr0,{ip} --nameserver '{' '.join(net['nameservers'])}' "
                f"--onboot 1 --protection 1 --dev0 /dev/net/tun "   # Tailscale needs a TUN device
                
                f"--description 'Yggdrasil, the root of the homelab. Not managed by Terraform. "
                f"Before removing it: bootstrap.py --host {ROOT} backup, then untick Protection.'")
    ssh(target, f"pct start {cfg['ctid']}")
    print(f"✔ {ROOT} is up at {cfg['address']} — `pct enter {cfg['ctid']}` on Proxmox to get in.")


def step_backup_root(proxmox):
    """vzdump Yggdrasil to the NAS, keeping the newest few."""
    cfg, target = SITE["yggdrasil"], f"root@{proxmox}"
    print(f"\n═══ Back up {ROOT} (CT {cfg['ctid']}) ═══")
    require_backup_storage(proxmox)
    if not guest_exists(proxmox, cfg["ctid"]):
        sys.exit(f"✕ CT {cfg['ctid']} doesn't exist — nothing to back up.")
    ssh(target, f"vzdump {cfg['ctid']} --storage syno-nfs --mode snapshot --compress zstd "
                f"--prune-backups keep-last=7")
    newest = latest_remote(proxmox, f"{PROXMOX_BACKUP_DIR}/vzdump-lxc-{cfg['ctid']}-*.tar.zst")
    print(f"✔ {newest}")


def step_restore_root(proxmox, from_file):
    """Bring Yggdrasil back from a backup into an empty CT id, protected again."""
    cfg, target = SITE["yggdrasil"], f"root@{proxmox}"
    print(f"\n═══ Restore {ROOT} (CT {cfg['ctid']}) ═══")
    if guest_exists(proxmox, cfg["ctid"]):
        sys.exit(f"✕ CT {cfg['ctid']} still exists — remove it by hand first (untick Protection).")
    backup = from_file or latest_remote(proxmox, f"{PROXMOX_BACKUP_DIR}/vzdump-lxc-{cfg['ctid']}-*.tar.zst")
    if not backup:
        sys.exit(f"✕ No backup of CT {cfg['ctid']} in {PROXMOX_BACKUP_DIR}.")
    ssh(target, f"pct restore {cfg['ctid']} {backup} --storage local-zfs --unprivileged 1")
    ssh(target, f"pct set {cfg['ctid']} --protection 1 && pct start {cfg['ctid']}")
    print(f"✔ {ROOT} restored from {Path(backup).name}.")


# ── Rotation ───────────────────────────────────────────────────────────────
# Every rotation works on copies first and only replaces the real files once
# each copy decrypts with the new key — a rotation stopped halfway never leaves
# a mix of files encrypted for the old key and the new one.

def age_public(keyfile):
    return subprocess.run(["age-keygen", "-y", str(keyfile)], check=True,
                          capture_output=True, text=True).stdout.strip()


def new_age_key(path):
    subprocess.run(["age-keygen", "-o", str(path)], check=True, capture_output=True)
    path.chmod(0o600)
    return age_public(path)


def sops_set(file, key, value):
    """Set one key in a sops file; the value goes through stdin, never argv."""
    subprocess.run(["sops", "set", "--value-stdin", str(SECRETS_DIR / file), f'["{key}"]'],
                   input=json.dumps(value), text=True, check=True)


def sops_rotate(path, add, remove):
    """New data key for the file, with `add` replacing `remove` as a recipient."""
    subprocess.run(["sops", "rotate", "--in-place", "--add-age", add, "--rm-age", remove, str(path)],
                   check=True, env=dict(os.environ, SOPS_AGE_KEY_FILE=str(ADMIN_KEY)))


def decrypts_with(path, keyfile):
    """True when `keyfile` alone opens the file — with an empty HOME, so sops
    can't quietly fall back on the admin key in its default location."""
    with tempfile.TemporaryDirectory() as home:
        env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=home, SOPS_AGE_KEY_FILE=str(keyfile))
        return subprocess.run(["sops", "--decrypt", str(path)], env=env,
                              capture_output=True).returncode == 0


def set_recipient(name, pub):
    """Point the `&name` anchor in .sops.yaml at a new public key."""
    lines = SOPS_CONFIG.read_text().splitlines(keepends=True)
    for i, line in enumerate(lines):
        if line.lstrip().startswith(f"- &{name} "):
            lines[i] = line.split(f"&{name}")[0] + f"&{name} " + " " * max(0, 11 - len(name)) + pub + "\n"
            break
    else:
        sys.exit(f"✕ No &{name} key in {SOPS_CONFIG}")
    SOPS_CONFIG.write_text("".join(lines))


def rotate_files(files, add, remove, check_key):
    """sops-rotate copies of `files`, verify them with `check_key`, then swap them in."""
    with tempfile.TemporaryDirectory() as work:
        staged = []
        for f in files:
            copy = Path(work) / f.name
            shutil.copy2(f, copy)
            print(f"✦ sops rotate {f.relative_to(REPO_ROOT)}")
            sops_rotate(copy, add, remove)
            if not decrypts_with(copy, check_key):
                sys.exit(f"✕ {f.name} doesn't decrypt with the new key — nothing was replaced.")
            staged.append((copy, f))
        for copy, f in staged:
            shutil.copy2(copy, f)


def deployed_hosts(proxmox):
    """Hosts with an image recorded on the Proxmox host, i.e. VMs that exist."""
    out = subprocess.run(["ssh", *ssh_opts(), f"root@{proxmox}",
                          f"cat {PROXMOX_STATE_DIR}/images.auto.tfvars.json 2>/dev/null || echo '{{}}'"],
                         check=True, capture_output=True, text=True).stdout
    return [h for h in HOSTS if h in json.loads(out).get("images", {})]


def ask_secret(prompt):
    first = getpass.getpass(f"{prompt}: ")
    if not first or first != getpass.getpass(f"{prompt} (again): "):
        sys.exit("✕ Empty, or the two entries differ.")
    return first


def rotate_console_password(proxmox, user):
    """The one password you type: VM consoles and the registry share it.
    Stored only as hashes — yescrypt for the consoles, bcrypt for the
    registry (the only kind it accepts) — then switched onto the VMs."""
    print("\n═══ Rotate the console + registry password ═══")
    password = ask_secret("New password")

    def hashed(method, *extra):
        return subprocess.run(["mkpasswd", f"--method={method}", *extra, "--stdin"], input=password,
                              check=True, capture_output=True, text=True).stdout.strip()

    sops_set("common.yaml", "console_password", hashed("yescrypt"))
    sops_set("common.yaml", "registry_htpasswd", f"{REGISTRY_USER}:{hashed('bcrypt', '--rounds=10')}")
    for h in deployed_hosts(proxmox):
        step_switch(h, user)
    print(f"✔ Consoles and the registry (user {REGISTRY_USER}) now take the new password — "
          "store it in Vaultwarden.")

def rotate_admin_passphrase():
    """Re-encrypt admin-key.age with a new passphrase (age asks for it)."""
    print("\n═══ Rotate the admin-key.age passphrase ═══")
    tmp = ADMIN_KEY_AGE.with_suffix(".age.new")
    run(["age", "--passphrase", "--output", tmp, ADMIN_KEY])
    os.replace(tmp, ADMIN_KEY_AGE)
    print("✔ Update the passphrase in Vaultwarden, then `build` to refresh the kits on the NAS.")


def rotate_admin_key():
    """A new admin key for every secret file, plus a new data key in each."""
    print("\n═══ Rotate the admin key ═══")
    old_pub = age_public(ADMIN_KEY)
    with tempfile.TemporaryDirectory() as work:
        new_key = Path(work) / "keys.txt"
        new_pub = new_age_key(new_key)
        rotate_files(sorted(SECRETS_DIR.glob("*.yaml")), new_pub, old_pub, new_key)
        set_recipient("admin", new_pub)

        # Keep the old key until you've checked everything still works
        old_copy = ADMIN_KEY.with_suffix(".txt.old")
        shutil.copy2(ADMIN_KEY, old_copy)
        shutil.copy2(new_key, ADMIN_KEY)
        ADMIN_KEY.chmod(0o600)
    print(f"✔ New admin key in {ADMIN_KEY}; the old one is {old_copy} — delete it once you're sure.")
    rotate_admin_passphrase()
    print("✔ Replace the admin key on the Mac, in Vaultwarden and on the NAS.")


def rotate_host_key(host, proxmox, user):
    """A new age key for one host: re-encrypt its files, then hand it to the VM
    without a moment where the VM couldn't decrypt its own secrets."""
    print(f"\n═══ Rotate the age key of {host} ═══")
    with tempfile.TemporaryDirectory() as work:
        old_key, new_key = Path(work) / "old.txt", Path(work) / "new.txt"
        old_key.write_text(sops_decrypt("hosts.yaml", host))
        old_pub = age_public(old_key)
        new_pub = new_age_key(new_key)

        files = [SECRETS_DIR / "common.yaml"] + [f for f in [SECRETS_DIR / f"{host}.yaml"] if f.exists()]
        rotate_files(files, new_pub, old_pub, new_key)
        set_recipient(host, new_pub)
        sops_set("hosts.yaml", host, new_key.read_text())

        local_copy = AGE_DIR / "hosts" / f"{host}.txt"
        if local_copy.exists():
            shutil.copy2(new_key, local_copy)

        if host in deployed_hosts(proxmox):
            # Both keys while the new files are deployed, then only the new one
            target = f"{user or vm_user(host)}@{host}"
            ssh(target, f"sudo sh -c 'cat >> {VM_AGE_KEY}'", input=new_key.read_text(), text=True)
            step_switch(host, user)
            ssh(target, f"sudo install -m 600 /dev/stdin {VM_AGE_KEY}", input=new_key.read_text(), text=True)
    print(f"✔ {host} has a new age key. Rebuild its image (`build --image`) before you recreate the VM.")


def rotate_proxmox_token(proxmox):
    """A new Terraform API token with the old one's permissions; the old one is
    removed only after the new one has answered the API."""
    print("\n═══ Rotate the Proxmox API token ═══")
    old = sops_decrypt("terraform.yaml", "proxmox_api_token").strip()
    userid, old_tokenid = old.split("=")[0].split("!")
    new_tokenid = f"terraform-{datetime.now():%Y%m%d%H%M}"
    target = f"root@{proxmox}"

    out = ssh(target, f"pveum user token add {userid} {new_tokenid} --privsep 1 --output-format json",
              capture_output=True, text=True).stdout
    new = f"{userid}!{new_tokenid}={json.loads(out)['value']}"

    acls = json.loads(ssh(target, "pveum acl list --output-format json", capture_output=True, text=True).stdout)
    for acl in acls:
        if acl.get("type") == "token" and acl.get("ugid") == f"{userid}!{old_tokenid}":
            ssh(target, f"pveum acl modify {acl['path']} --tokens '{userid}!{new_tokenid}' "
                        f"--roles {acl['roleid']} --propagate {acl.get('propagate', 1)}")

    request = urllib.request.Request(f"https://{proxmox}:8006/api2/json/nodes",
                                     headers={"Authorization": f"PVEAPIToken={new}"})
    with urllib.request.urlopen(request, context=ssl._create_unverified_context()) as response:
        if response.status != 200 or not json.load(response).get("data"):
            sys.exit(f"✕ The new token {new_tokenid} can't list nodes — the old one was kept.")

    sops_set("terraform.yaml", "proxmox_api_token", new)
    # Removing a token leaves its ACL entries behind in user.cfg — drop them first
    for acl in acls:
        if acl.get("type") == "token" and acl.get("ugid") == f"{userid}!{old_tokenid}":
            ssh(target, f"pveum acl delete {acl['path']} --tokens '{userid}!{old_tokenid}' --roles {acl['roleid']}")
    ssh(target, f"pveum user token remove {userid} {old_tokenid}")
    print(f"✔ Terraform now uses {userid}!{new_tokenid}; {old_tokenid} is gone.")


def rotate_ssh_key(proxmox, user):
    """A new SSH key for Proxmox root and every VM user. The new key is
    authorized everywhere before the old one is removed anywhere."""
    print("\n═══ Rotate the SSH key (Proxmox root + VM users) ═══")
    target   = f"root@{proxmox}"
    old_pub  = SITE["sshKey"]
    old_body = old_pub.split()[1]
    deployed = deployed_hosts(proxmox)

    with tempfile.TemporaryDirectory() as work:
        new_key = Path(work) / "id_ed25519"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", f"homelab-{datetime.now():%Y%m%d}",
                        "-f", str(new_key)], check=True)
        new_pub = new_key.with_suffix(".pub").read_text().strip()

        # 1. Proxmox accepts both keys
        ssh(target, "cat >> /root/.ssh/authorized_keys", input=new_pub + "\n", text=True)

        # 2. VMs get the new key (deployed with the old one, which still works)
        SITE["sshKey"] = new_pub
        SITE_FILE.write_text(json.dumps(SITE, indent=2, ensure_ascii=False) + "\n")
        for h in deployed:
            step_switch(h, user)

        # 3. From here on, everything uses the new key
        sops_set("terraform.yaml", "proxmox_ssh_key", new_key.read_text())
        ssh_key().write_text(new_key.read_text())
        ssh(target, "true")
        for h in deployed:
            ssh(f"{user or vm_user(h)}@{h}", "true")

        # 4. Only now drop the old key. `cat >` keeps the symlink into /etc/pve/priv
        ssh(target, f"grep -vF '{old_body}' /root/.ssh/authorized_keys > /tmp/authorized_keys.new && "
                    "cat /tmp/authorized_keys.new > /root/.ssh/authorized_keys && rm /tmp/authorized_keys.new")
    print("✔ New SSH key everywhere; the old one is no longer accepted on Proxmox or the VMs.")


def rotate_secret(file, key, from_file):
    """Any other value, made somewhere else (e.g. a Tailscale auth key)."""
    print(f"\n═══ Rotate {key} in {file} ═══")
    value = Path(from_file).read_text() if from_file else ask_secret(f"New value for {key}")
    sops_set(file, key, value)
    print("✔ Run `switch` on the VMs that use it.")


# ── CLI ────────────────────────────────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(description="Homelab bootstrap orchestrator")
    parser.add_argument("--host", default=None, choices=HOSTS + [ROOT], help="Target host (default: all VMs)")
    parser.add_argument("--user", default=None, help="VM user for switch (default: from bifrost.users)")
    parser.add_argument("--proxmox", default=PROXMOX_HOST, help="Proxmox host to build on/deploy to")

    sub = parser.add_subparsers(dest="command", required=True)

    # ── build ──
    build = sub.add_parser("build", help="Build template + kit, upload to the NAS")
    build.add_argument("--image", action="store_true", help="Also make the qcow2 image")

    # ── clean ──
    clean = sub.add_parser("clean", help="Clean artifacts")
    clean.add_argument("--all", action="store_true", help="--archives --images --store")
    clean.add_argument("--archives", action="store_true", help="Templates + kits (local links, NAS)")
    clean.add_argument("--images", action="store_true", help="qcow2 files in local:import")
    clean.add_argument("--store", action="store_true", help="nix store gc, locally")

    # ── switch ──
    sub.add_parser("switch", help="Build, copy and activate the config on the running VM")

    # ── seed ──
    seed = sub.add_parser("seed", help="Copy a service's data to --host, once, before its first switch")
    seed.add_argument("service", help="e.g. gitea — copies share/services/gitea/data")

    # ── init ──
    init = sub.add_parser("init", help="Initialize or destroy infrastructure")
    init.add_argument("--apply", action="store_true", help="Terraform apply")
    init.add_argument("--destroy", action="store_true", help="Terraform destroy")
    init.add_argument("--yes", action="store_true", help="Don't ask for confirmation")

    # ── yggdrasil ──
    sub.add_parser("create", help="Create the root LXC (--host yggdrasil)")
    sub.add_parser("backup", help="Back up the root LXC to the NAS (--host yggdrasil)")
    restore = sub.add_parser("restore", help="Restore the root LXC from its newest backup (--host yggdrasil)")
    restore.add_argument("--from", dest="from_file", help="A specific vzdump file on the Proxmox host")

    # ── rotate ──
    rotate = sub.add_parser("rotate", help="Rotate keys, passwords and tokens")
    what = rotate.add_subparsers(dest="what", required=True)
    what.add_parser("console-password", help="The one password you type: VM consoles + registry")
    what.add_parser("admin-passphrase", help="Passphrase of admin-key.age")
    what.add_parser("admin-key", help="The sops admin key (all files get a new data key)")
    what.add_parser("host-key", help="The age key of --host")
    what.add_parser("proxmox-token", help="Terraform's Proxmox API token")
    what.add_parser("ssh-key", help="SSH key for Proxmox root and every VM user")
    secret = what.add_parser("secret", help="Any value made elsewhere, e.g. tailscale_key")
    secret.add_argument("file", help="e.g. common.yaml")
    secret.add_argument("key", help="e.g. tailscale_key")
    secret.add_argument("--from-file", help="Read a multi-line value from this file")

    return parser.parse_args()


def main():
    # sops/terraform come from the flake's devShell when not already installed
    if not shutil.which("sops") and "IN_NIX_SHELL" not in os.environ:
        os.execvp("nix", ["nix", "develop", FLAKE, "-c", "python3", __file__, *sys.argv[1:]])

    args  = parse_args()
    hosts = [args.host] if args.host else HOSTS

    if ROOT in hosts and (args.command in ("init", "switch") or getattr(args, "image", False)):
        sys.exit(f"✕ {ROOT} isn't a Terraform VM: `build` it, then `create`, `backup` or `restore` it.")
    if args.command in ("create", "backup", "restore") and args.host != ROOT:
        sys.exit(f"✕ `{args.command}` is only for the root LXC: add --host {ROOT}.")

    if args.command == "build":
        for h in hosts:
            step_build(h, args.proxmox, build_image=args.image)

    elif args.command == "clean":
        for h in hosts:
            step_clean(h, args.proxmox, archives=args.archives or args.all,
                       images=args.images or args.all, store=False)
        if args.store or args.all:
            step_clean(None, args.proxmox, archives=False, images=False, store=True)

    elif args.command == "init":
        if args.apply and args.destroy:
            sys.exit("✕ --apply and --destroy are exclusive.")
        step_init(hosts, args.proxmox, args.apply, args.destroy, args.yes)

    elif args.command == "create":
        step_create_root(args.proxmox)

    elif args.command == "backup":
        step_backup_root(args.proxmox)

    elif args.command == "restore":
        step_restore_root(args.proxmox, args.from_file)

    elif args.command == "rotate":
        if args.what == "console-password":
            rotate_console_password(args.proxmox, args.user)
        elif args.what == "admin-passphrase":
            rotate_admin_passphrase()
        elif args.what == "admin-key":
            rotate_admin_key()
        elif args.what == "host-key":
            if not args.host or args.host == ROOT:
                sys.exit("✕ rotate host-key needs --host <vm>.")
            rotate_host_key(args.host, args.proxmox, args.user)
        elif args.what == "proxmox-token":
            rotate_proxmox_token(args.proxmox)
        elif args.what == "ssh-key":
            rotate_ssh_key(args.proxmox, args.user)
        elif args.what == "secret":
            rotate_secret(args.file, args.key, args.from_file)

    elif args.command == "seed":
        if not args.host or args.host == ROOT:
            sys.exit("✕ seed needs --host <vm>.")
        step_seed(args.host, args.service, args.user)

    elif args.command == "switch":
        for h in hosts:
            step_switch(h, args.user)

    print("\n✔ Done.")


if __name__ == "__main__":
    main()
