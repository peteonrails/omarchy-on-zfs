# Installing Omarchy on ZFS

This guide walks through setting up Omarchy on a ZFS root filesystem using
ZFSBootMenu (ZBM) as the bootloader. Stock Omarchy expects btrfs + Limine;
this guide covers the ZFS alternative.

## Who this is for

- **Primary audience:** You want a fresh Arch Linux install on ZFS with
  Omarchy as your desktop, using ZFSBootMenu for boot management.
- **Advanced audience:** You already have a ZFS pool running another OS
  (CachyOS, Ubuntu, etc.) and want to add Omarchy as an additional boot
  environment. Jump to [Appendix A](#appendix-a-dual-boot-alongside-an-existing-zfs-os).

If you're on btrfs, don't use this guide -- the standard Omarchy install
flow handles everything for you.

## Should you use ZFS at all?

Linux is about choices, but Omarchy is about having a tasteful opinion.
Stock Omarchy's opinion is btrfs + Limine + Snapper -- a tidy,
single-disk, laptop-friendly stack that works great for most people.
This ZFS path is here for folks whose hardware or ecosystem makes ZFS
the right answer, not as a general upgrade.

**Stay on btrfs (the default) if:**

- You're on a laptop with a single SSD. btrfs + Snapper + Limine is
  simpler, needs no pre-install setup, and covers snapshot rollback just
  fine for one disk.
- You have a Synology NAS. Synology uses btrfs natively -- shared-send,
  snapshot interoperability, and general ecosystem alignment all favor
  btrfs here.
- You have a stock OpenMediaVault or Rockstor setup. Both use btrfs by
  default (OMV supports ZFS via a plugin, but it's not the grain).
- You don't have a strong reason to pick ZFS. btrfs is perfectly
  capable.

**Consider ZFS if:**

- **Desktop with multiple drives.** ZFS pools (mirrors, raidz, hybrid
  vdevs with special devices for metadata/cache) genuinely shine when
  you've got several disks. btrfs's multi-disk story is workable but
  lighter than ZFS's.
- **You run TrueNAS or another ZFS NAS.** End-to-end ZFS means
  `zfs send`/`zfs recv` backups, identical snapshot semantics, and
  matching tooling. If your backup target is ZFS, making your desktop
  ZFS is the obvious move.
- **You want ZFS native encryption** instead of the LUKS layer btrfs
  inherits from the Arch install.
- **You want per-dataset mount control** for finer snapshot scoping
  (separate `varcache`/`varlog`/`home` from the root BE so system
  rollback doesn't nuke your pacman cache or logs).
- **You want ZFSBootMenu.** ZBM is a best-in-class experience for ZFS
  boot environments. Specifically:
  - **Native snapshot browsing.** Limine + `limine-snapper-sync` can
    boot into btrfs snapshots too, but it works by pre-generating a
    boot entry for each snapshot and writing them into the Limine
    config (managed entries that need to stay in sync). ZBM queries
    ZFS at boot time -- snapshots are discovered live, no entries to
    manage. From the menu you can clone, rollback, diff, or chroot
    into any snapshot.
  - **Remote unlock over SSH.** ZBM can bundle dropbear into its
    initramfs (mkinitcpio `dropbear` hook on Arch). SSH in at boot
    time, run `zfs load-key`, select a BE, and the system boots.
    Useful for headless boxes and remote servers.
  - **Encrypted-by-default backups.** With ZFS native encryption,
    `zfs send --raw` (`-w`) sends encrypted blocks as-is, including
    the wrapped master key but never the passphrase. The receiving
    server can store your backup but literally cannot read it. Safe
    to send to an untrusted target (a friend's NAS, a VPS, etc.).

## Tradeoffs of the ZFS path

- **You set up the pool and ZBM.** Stock Omarchy inherits this from
  archinstall. The ZFS path requires manual work before running the
  Omarchy installer.
- **`zfs-dkms` / `zfs-utils` are AUR packages** (unless your repo
  provides them prebuilt, like CachyOS). DKMS rebuilds on kernel
  updates. Plan on a slower `pacman -Syu` than btrfs users see.
- **No Snapper integration out of the box.** Omarchy's snapshot CLI
  uses native `zfs snapshot` / `zfs rollback` on ZFS. You lose Snapper's
  pre/post pacman transaction snapshots (though you can replicate this
  with a pacman hook and a `zfs snapshot` wrapper).
- **Limine is replaced by ZFSBootMenu.** ZBM is purpose-built for ZFS
  and is a superior experience there, but it's a different tool with
  its own learning curve.

---

## Two paths: scripted or manual

There are two ways to get to a working Omarchy-on-ZFS install:

### Scripted (recommended)

**Boot from `r-maerz/archlinux-lts-zfs`**, not the stock Arch ISO. This is
an archlinux ISO with the LTS kernel and prebuilt `zfs-linux-lts` modules
already loaded — kernel and ZFS are version-paired by archzfs's build.

Latest release: <https://github.com/r-maerz/archlinux-lts-zfs/releases>
(monthly cadence, ~1.5 GB). Burn it or boot in a VM, log in as `root`,
get networking working, then:

```
curl -fsSL https://raw.githubusercontent.com/peteonrails/omarchy-on-zfs/omarchy-zfs/bootstrap/iso-zfs.sh | bash
```

This runs `bin/omarchy-bootstrap-zfs`, which performs every step in this
document end-to-end: partitions the disk(s), creates the pool, lays out
datasets, pacstraps the base system with `linux-lts` + `zfs-linux-lts`,
configures the chroot, installs ZFSBootMenu, registers the EFI boot
entry, and hands off to `install.sh`.

It supports single-disk, mirror, raidz1/2/3, and fresh-pool *or* import
of an existing pool (Appendix A dual-boot). Home is shared at
`zroot/data/home` by default — per-BE home isolation is no longer a
default option (it was rarely the right call for desktop installs).

Use `--dry-run` to preview every command without changing anything, or
`--resume` to pick back up after a failure.

**Why the LTS-zfs ISO instead of stock Arch:** the stock Arch ISO has
no ZFS modules. We used to build `zfs-dkms-git` from a pinned OpenZFS
commit at install time to compensate, but that traded freshness — the
installed system was frozen on the build commit. Booting an archzfs-
equipped ISO eliminates that trap: kernel and ZFS modules are paired
by archzfs at release time, and `pacman -Syu` afterward keeps them
paired automatically. No DKMS rebuilds.

### Manual

The rest of this document is the manual procedure the script automates.
Use it if you want fine-grained control, are debugging the script, or
need a configuration the v1 script doesn't cover (e.g. ESP mirroring
across all pool members, custom dataset names, multi-vdev pools with
special/log/cache devices).

## Prerequisites

Before running the Omarchy installer, you need:

1. An Arch Linux base install living on a ZFS dataset
2. ZFSBootMenu installed on the EFI System Partition (ESP)
3. A working network connection in the installed system

The simplest path is to follow the [ArchWiki: Install Arch Linux on
ZFS](https://wiki.archlinux.org/title/Install_Arch_Linux_on_ZFS) guide
through step "Configure the new system" (inside the chroot). The rest of
this guide fills in the gaps that the wiki leaves open, particularly
around ZBM and the Omarchy-specific dataset layout.

### Hardware requirements

- x86_64 CPU
- UEFI firmware with Secure Boot **disabled**
- At least one EFI System Partition formatted FAT32

### Packages required before running Omarchy

Inside your chroot / new system:

```
pacman -S base base-devel linux linux-firmware linux-headers \
          sudo git iwd \
          zfs-utils zfs-dkms   # from AUR or an Arch ZFS repo
```

---

## Step 1: Create the ZFS pool

Omarchy's installer doesn't touch partitioning. You need to have already
created:

- An ESP (vfat, ~500MB-1GB)
- A ZFS pool on the rest of the disk

Example pool creation (customize for your disk):

```
zpool create -f \
  -o ashift=12 \
  -o autotrim=on \
  -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
  -O compression=zstd \
  -O normalization=formD \
  -O relatime=on -O atime=off \
  -O mountpoint=none -O canmount=off \
  -O encryption=aes-256-gcm \
  -O keyformat=passphrase \
  -O keylocation=prompt \
  -R /mnt \
  zroot /dev/nvme0n1p2
```

You'll be prompted for an encryption passphrase during pool creation.
Remember it -- it unlocks your system at boot.

Pool name is `zroot` (Arch wiki convention). Older fork installs used
`rpool` (FreeBSD heritage); both work — runtime tooling discovers the
pool name dynamically. New installs default to `zroot`.

## Step 2: Create the dataset layout

The fork's bootstrap script creates this layout (matches the
[Install Arch Linux on ZFS](https://wiki.archlinux.org/title/Install_Arch_Linux_on_ZFS)
wiki guide):

```
zroot/ROOT                       (container, no mount)
zroot/ROOT/default               -> /                   (the boot environment)
zroot/data                       (container)
zroot/data/home                  -> /home               (shared across BEs)
zroot/data/root                  -> /root
zroot/var                        (container)
zroot/var/log                    -> /var/log
zroot/var/log/journal            -> /var/log/journal    (posixacl)
zroot/var/cache                  -> /var/cache
zroot/var/tmp                    -> /var/tmp
zroot/var/lib/docker             -> /var/lib/docker     (per-service rollback)
zroot/var/lib/libvirt            -> /var/lib/libvirt
zroot/var/lib/machines           -> /var/lib/machines
zroot/keystore                   -> /etc/zfs/keys       (encryption key)
```

Create them:

```
zfs create -o mountpoint=none -o canmount=off zroot/ROOT
zfs create -o mountpoint=/    -o canmount=noauto zroot/ROOT/default
zfs create -o mountpoint=none -o canmount=off zroot/data
zfs create -o mountpoint=/home zroot/data/home
zfs create -o mountpoint=/root zroot/data/root
zfs create -o mountpoint=none -o canmount=off zroot/var
zfs create -o mountpoint=/var/log zroot/var/log
zfs create -o mountpoint=/var/log/journal -o acltype=posixacl zroot/var/log/journal
zfs create -o mountpoint=/var/cache zroot/var/cache
zfs create -o mountpoint=/var/tmp zroot/var/tmp
zfs create -o mountpoint=none -o canmount=off zroot/var/lib
zfs create -o mountpoint=/var/lib/docker   zroot/var/lib/docker
zfs create -o mountpoint=/var/lib/libvirt  zroot/var/lib/libvirt
zfs create -o mountpoint=/var/lib/machines zroot/var/lib/machines
zfs create -o mountpoint=/etc/zfs/keys     zroot/keystore
zpool set bootfs=zroot/ROOT/default zroot
```

Why separate datasets? When you take a snapshot of `zroot/ROOT/default`
and later roll back, child datasets (var/log, var/cache, home, etc.)
aren't affected. That means:

- System rollback doesn't destroy your pacman cache (saves re-downloads)
- System rollback doesn't destroy your logs (keeps incident history)
- System rollback doesn't touch your home directory

## Step 3: Mount and bootstrap

```
mkdir -p /mnt
zfs mount zroot/ROOT/default        # mounts at /mnt if it's your altroot, else /
zfs mount zroot/var/cache
zfs mount zroot/var/log
zfs mount zroot/data/home

# Mount ESP
mkdir -p /mnt/boot/efi
mount /dev/nvme0n1p1 /mnt/boot/efi

# Install base system
pacstrap /mnt base base-devel linux linux-firmware linux-headers \
              sudo git iwd zfs-utils zfs-dkms

# Generate fstab (captures your ESP; we'll add ZFS entries manually)
genfstab -U /mnt >> /mnt/etc/fstab
```

## Step 4: Configure the new system (in chroot)

```
arch-chroot /mnt
```

Inside the chroot, configure the things that Omarchy's installer
intentionally does not (because they're normally done by archinstall):

### 4a. Hostname, timezone, locale

```
echo "my-hostname" > /etc/hostname
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf
```

### 4b. User account

```
useradd -m -G wheel,audio,video,input,storage,lp,sys,network,users,rfkill pete
# Omarchy will sync this password with your ZFS passphrase, but set one now:
passwd pete

# Enable sudo for wheel
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Root password (or leave locked)
passwd
```

### 4c. Networking (systemd-networkd + iwd)

Omarchy uses iwd for Wi-Fi and systemd-networkd for DHCP/Ethernet.
archinstall normally sets this up; for a manual install, do it yourself:

```
systemctl enable systemd-networkd.service
systemctl enable systemd-resolved.service
systemctl enable iwd.service

mkdir -p /etc/systemd/network /etc/iwd

cat > /etc/systemd/network/20-wired.network <<EOF
[Match]
Name=en*

[Network]
DHCP=yes
DNSSEC=no
EOF

cat > /etc/systemd/network/25-wireless.network <<EOF
[Match]
Name=wl*

[Network]
DHCP=yes
DNSSEC=no
EOF

cat > /etc/iwd/main.conf <<EOF
[General]
EnableNetworkConfiguration=false

[Network]
NameResolvingService=systemd
EOF

ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
```

### 4d. ZFS fstab entries

`genfstab` captured your ESP but won't emit ZFS entries. Add them:

```
cat >> /etc/fstab <<EOF

# ZFS boot-environment datasets (canmount=noauto, explicit mount)
zroot/var/cache  /var/cache  zfs  defaults,zfsutil  0 0
zroot/var/log    /var/log    zfs  defaults,zfsutil  0 0
zroot/data/home      /home       zfs  defaults,zfsutil  0 0
EOF
```

### 4e. Set the zpool cachefile

```
zpool set cachefile=/etc/zfs/zpool.cache zroot
```

This lets the initramfs import the pool on boot without scanning.

## Step 5: Install ZFSBootMenu

ZBM lives on the ESP and is entirely separate from any boot environment.
You install it once and it manages all ZFS boot environments on the pool.

```
mkdir -p /etc/zfsbootmenu

cat > /etc/zfsbootmenu/config.yaml <<EOF
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
  InitCPIO: true
Components:
  Enabled: false
EFI:
  Enabled: true
  ImageDir: /boot/efi/EFI/zbm
  Versions: 2
Kernel:
  CommandLine: quiet loglevel=0 zbm.skip_hooks=
EOF

# Install ZBM (via AUR)
sudo -u pete yay -S zfsbootmenu

# Generate the EFI image
generate-zbm
```

Add a UEFI boot entry that points to the ZBM EFI image:

```
efibootmgr --create \
  --disk /dev/nvme0n1 \
  --part 1 \
  --label "ZFSBootMenu" \
  --loader '\EFI\zbm\vmlinuz.EFI'
```

## Step 6: Set the ZBM kernel command line on your dataset

ZBM reads the per-dataset `org.zfsbootmenu:commandline` property to know
what to pass to the kernel when booting this BE:

```
zfs set org.zfsbootmenu:commandline='quiet splash rw' zroot/ROOT/default
```

## Step 7: Run the Omarchy installer

Still inside the chroot:

```
su - pete
curl -fsSL https://omarchy.org/install | bash
```

On the `omarchy-zfs` branch, the installer will:

- Detect ZFS as the root filesystem
- Install `zfs-utils` and `zfs-dkms` from AUR if not already present
- Set the correct mkinitcpio hooks (`zfs` instead of `btrfs-overlayfs`, no
  `encrypt` since we use ZFS native encryption)
- Embed your ZFS key file into the initramfs so ZBM and the kernel don't
  both prompt for the passphrase
- Sync your user login password with the ZFS passphrase
- Seed `/etc/zfs/zfs-list.cache/<pool>` for `zfs-mount-generator` and
  enable `zfs-zed.service` to keep it in sync
- Install Omarchy ZBM branding hooks (Tokyo Night theme + branded unlock
  screen) to `/etc/zfsbootmenu/hooks/`

After the installer completes, exit the chroot, unmount everything, and
reboot.

## Step 8: First boot

You should see:

1. **ZBM** prompt for the encryption passphrase (once -- the initramfs
   uses the embedded key for the re-import)
2. ZBM displays your boot environments (`zroot/ROOT/default` is the only
   one for a fresh install)
3. Select it and the system boots
4. SDDM auto-login for the user
5. Hyprland starts with Omarchy's desktop

## Verification

After login, run these to confirm the setup:

```
# Filesystem is zfs
findmnt /

# Separate datasets for /home, /var/cache, /var/log
findmnt /home /var/cache /var/log

# Network is up (ethernet or wifi)
ip -4 addr

# Sound works
wpctl status   # should show sinks and sources

# No boot errors
journalctl -b --priority=err
```

---

## Appendix A: Dual-boot alongside an existing ZFS OS

This section covers installing Omarchy as an additional boot environment
on a ZFS pool that's already running another OS (e.g., CachyOS, Ubuntu).
The same pool, different root dataset.

Omarchy's Step 2 dataset layout works as-is -- the container dataset
`zroot` is separate from whatever your other OS uses
(`zroot/cachyos`, `zroot/ubuntu`, etc.).

### Isolation concerns

Both OSes share the same pool, so shared datasets like `zroot/home`
(mountpoint=/home, canmount=on) will auto-mount on both. That's usually
not what you want for initial testing -- it means Omarchy's hyprland
configs would leak into your other OS's home, or vice versa.

For fully isolated testing, swap the shared `zroot/data/home` for a
per-BE home dataset:

**1. Create a per-BE home dataset** with `canmount=noauto` so it doesn't
auto-mount on the other OS:

```
zfs create -o mountpoint=/home -o canmount=noauto zroot/data/omarchy-home
```

**2. Tell `zfs-mount-generator` to skip the shared `zroot/data/home`** on
Omarchy:

```
zfs set org.openzfs.systemd:ignore=on zroot/data/home
```

This property only affects `zfs-mount-generator`. The other OS is
unaffected if it uses `zfs-mount.service` instead.

**3. Disable `zfs-mount.service` on Omarchy** so it doesn't pull in
the shared home:

```
systemctl disable zfs-mount.service
```

Why: `zfs-mount.service` runs `zfs mount -a` which mounts every
`canmount=on` dataset, including the shared `zroot/data/home`. It does
NOT respect the `org.openzfs.systemd:ignore` property. With it disabled,
Omarchy relies entirely on `zfs-mount-generator` for mounts. The
generator handles shared datasets like `zroot/keystore` correctly.

**4. Add an fstab entry** for the per-BE home so it mounts on this BE:

```
echo "zroot/data/omarchy-home  /home  zfs  defaults,zfsutil  0 0" | sudo tee -a /etc/fstab
```

### Cross-OS property visibility

`org.openzfs.systemd:ignore` is a ZFS property stored on the dataset,
visible to every OS that imports the pool. It's safe as long as the
other OS uses `zfs-mount.service` (which ignores the property). If the
other OS later switches to `zfs-mount-generator`, you'll need to revisit.

### Setting the default boot environment

ZBM's default boot is controlled by the pool's `bootfs` property:

```
# Keep the other OS as default:
zpool set bootfs=zroot/cachyos/root zroot

# Or make Omarchy default:
zpool set bootfs=zroot/ROOT/default zroot
```

Either way, both BEs show up in ZBM's menu at boot.

### Switching from per-BE home back to shared

If you started with the per-BE home isolation above and want to merge
back to a shared `zroot/data/home`:

```
# 1. Snapshot both sides first (safety net)
sudo zfs snapshot zroot/data/home@pre-merge-$(date +%Y%m%d)
sudo zfs snapshot zroot/data/omarchy-home@pre-merge-$(date +%Y%m%d)

# 2. Mount the shared home somewhere temporary
sudo mkdir -p /mnt/shared-home
sudo mount -t zfs -o zfsutil zroot/data/home /mnt/shared-home

# 3. Overlay per-BE configs onto the shared home (preview first)
rsync -av --dry-run --exclude='.cache' /home/$USER/ /mnt/shared-home/$USER/
# If the preview looks right:
rsync -av --exclude='.cache' /home/$USER/ /mnt/shared-home/$USER/

# 4. Drop the per-BE home from fstab and re-enable shared:
sudo sed -i '/zroot\/data\/omarchy-home/d' /etc/fstab
sudo zfs set org.openzfs.systemd:ignore=off zroot/data/home

# 5. Clean up
sudo umount /mnt/shared-home && sudo rmdir /mnt/shared-home
```

The per-BE dataset stays around as rollback. Don't delete it until
you're confident the merge is solid.

---

## Appendix B: ZBM branding (optional)

Omarchy ships branded hooks for ZBM at `/etc/zfsbootmenu/hooks/`:

- `setup.d/01-omarchy-theme.sh` -- Tokyo Night fzf theme for the boot menu
- `load-key.d/01-omarchy-unlock.sh` -- OMARCHY logo + styled passphrase prompt

For these to take effect, ZBM needs to know where to find them. Edit
`/etc/zfsbootmenu/config.yaml` to add:

```yaml
Global:
  ...
  PreHooksDir: /etc/zfsbootmenu/hooks
```

Then rebuild ZBM:

```
generate-zbm
```

The EFI image on the ESP now contains the branded hooks and will apply
them on next boot.

### Optional: BMP splash image

ZBM can display a BMP image during the UKI stub boot (before the TUI
menu appears). Save a BMP at `/etc/zfsbootmenu/splash.bmp` and add to
`config.yaml`:

```yaml
EFI:
  ...
  SplashImage: /etc/zfsbootmenu/splash.bmp
```

---

## Appendix C: Backup and replication with syncoid

One of ZFS's strongest features is `zfs send`/`zfs recv` — block-level
incremental replication of datasets. **syncoid** (from the sanoid package)
wraps this in a single command with bookmark tracking.

### Why replicate

Snapshots protect against accidental changes, but they live on the same
pool as your data. If the pool is lost (disk failure, accidental
`zpool destroy`), the snapshots go with it. Replication copies snapshots
to a second pool — a different disk, a NAS, a remote server — so you
have an independent copy.

### Install syncoid

syncoid ships as part of the sanoid package:

```
omarchy-pkg-aur-add sanoid
```

### Local replication (second pool on the same machine)

If you have a backup pool (e.g., `zbackup`), replicate your important
datasets to it:

```
# First run is a full send (may take a while)
syncoid --recursive --no-sync-snap zroot/ROOT/default zbackup/omarchy/root

# zroot/home: use --create-bookmark for incremental tracking
syncoid --recursive --create-bookmark zroot/home zbackup/home
```

Subsequent runs are incremental — only changed blocks are sent.

### Automating with a systemd timer

Create a service and timer to run replication daily:

```
# /etc/systemd/system/syncoid.service
[Unit]
Description=Replicate ZFS datasets to backup pool
After=zfs.target

[Service]
Type=oneshot
ExecStart=syncoid --recursive --no-sync-snap --create-bookmark zroot/ROOT/default zbackup/omarchy/root
ExecStart=syncoid --recursive --create-bookmark zroot/home zbackup/home
```

```
# /etc/systemd/system/syncoid.timer
[Unit]
Description=Daily ZFS replication

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

```
sudo systemctl daemon-reload
sudo systemctl enable --now syncoid.timer
```

### Remote replication (push to a NAS or server)

syncoid supports SSH natively:

```
syncoid --recursive zroot/home user@nas:zbackup/home
```

The remote side needs ZFS and the receiving user needs permission to
create datasets. For encrypted datasets, add `--sendoptions=w` to send
raw encrypted blocks (the remote can't read your data).

### What to replicate

| Dataset | Replicate? | Why |
|---------|-----------|-----|
| `zroot/ROOT/default` | Yes | System state, packages, configs |
| `zroot/data/home` | Yes | User data — the most important dataset |
| `zroot/data/root` | Yes | Root user's home (sudoers config edits, etc.) |
| `zroot/keystore` | Yes | Encryption keys for the pool |
| `zroot/var/log` | Optional | Logs; useful for incident forensics |
| `zroot/var/cache` | No | Pacman cache, easily re-downloaded |
| `zroot/var/tmp` | No | Transient by definition |
| `zroot/var/lib/docker` | Depends | Container state — replicate if you have running services with persistent volumes |
| `zroot/var/lib/libvirt` | Yes | VM disk images (large but irreplaceable) |
| `zroot/var/lib/machines` | Optional | systemd-nspawn containers |

### Encrypted replication

With ZFS native encryption, `syncoid --sendoptions=w` sends raw encrypted
blocks. The receiving pool stores the data encrypted with your key — it
cannot decrypt without your passphrase. This is safe for untrusted backup
targets.

---

## Appendix D: Home dataset strategy

ZFS's per-dataset mount control gives you a choice that btrfs doesn't:
whether `/home` is shared across boot environments or isolated per-BE.

### Shared home (the default)

The fork's bootstrap creates `zroot/data/home` mounted at `/home` and
shared across all boot environments — all BEs see the same `/home`.

**Good for:**
- Single-OS setups (Omarchy is your only OS) — the common case
- Preserving data across BE swaps and system rollbacks
- Avoiding duplicate data when you have hundreds of GB in your home dir

**Downside:** A system rollback doesn't roll back your home directory.
Desktop configs (hyprland, waybar, etc.) that changed between snapshots
won't revert. This is usually what you want, but be aware of it.

### Per-BE home (advanced, opt-in)

For dual-boot scenarios where you want config isolation between BEs,
swap the shared home for a per-BE one. See [Appendix A](#appendix-a-dual-boot-alongside-an-existing-zfs-os)
for the per-BE setup procedure.

**Good for:**
- Testing Omarchy alongside another OS without cross-contamination
- Clean separation of desktop environments (different hyprland configs)

**Downside:** Your data (documents, projects, media) is trapped inside
the BE. If you create a new BE, you start with an empty home.

---

## Troubleshooting

**Double passphrase prompt at boot**
The initramfs key embedding didn't work. Check that
`/etc/mkinitcpio.conf.d/omarchy_zfs_keys.conf` contains
`FILES+=(/etc/zfs/keys/zroot.key)` (or your key path), then rebuild:
`sudo mkinitcpio -P`.

**Ethernet doesn't work after install**
`systemd-networkd` / `systemd-resolved` may not be enabled. Check
`systemctl status systemd-networkd` and the `.network` files in
`/etc/systemd/network/`.

**Sound doesn't work**
The pipewire companion packages may be missing. Install them:
`sudo pacman -S pipewire-alsa pipewire-pulse pipewire-jack`. Then
`systemctl --user restart pipewire wireplumber`.

**ZBM doesn't see Omarchy in the boot menu**
Your dataset needs `mountpoint=/` for ZBM to recognize it as a boot
environment. Verify with `zfs get mountpoint zroot/ROOT/default`.

**`/home` mounts the wrong dataset (dual-boot)**
See [Appendix A](#appendix-a-dual-boot-alongside-an-existing-zfs-os) for
the `org.openzfs.systemd:ignore` + disable `zfs-mount.service` setup.

**Keystore dataset won't mount (dependency cycle)**
If you see `Found ordering cycle` in the journal involving
`etc-zfs-keys.mount` and `zfs-load-key@zroot.service`, the
zfs-mount-generator is creating a circular dependency. The installer
should have shipped a static mount unit to break this cycle. If it
didn't, create one manually:

```
sudo tee /etc/systemd/system/etc-zfs-keys.mount >/dev/null <<EOF
[Unit]
Description=Mount zroot/keystore at /etc/zfs/keys
DefaultDependencies=no
Before=local-fs.target
After=zfs-import.target
RequiresMountsFor=/etc

[Mount]
Where=/etc/zfs/keys
What=zroot/keystore
Type=zfs
Options=defaults,atime,relatime,nodev,exec,rw,suid,nomand,zfsutil

[Install]
WantedBy=local-fs.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now etc-zfs-keys.mount
```

**`Error: snapper configs not found` during install**
Ignore -- that's the btrfs code path. The Omarchy installer should skip
it on ZFS. If you see this error, confirm you're on the `omarchy-zfs`
branch.

---

## References

- [ArchWiki: ZFS](https://wiki.archlinux.org/title/ZFS)
- [ArchWiki: Install Arch Linux on ZFS](https://wiki.archlinux.org/title/Install_Arch_Linux_on_ZFS)
- [ZFSBootMenu documentation](https://docs.zfsbootmenu.org/)
- [ZFS Boot Environments primer](https://docs.zfsbootmenu.org/en/v3.1.x/general/bootenvs-and-you.html)
