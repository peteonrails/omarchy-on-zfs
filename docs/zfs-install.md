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
  -O mountpoint=none \
  -O encryption=aes-256-gcm \
  -O keyformat=passphrase \
  -O keylocation=prompt \
  rpool /dev/nvme0n1p2
```

You'll be prompted for an encryption passphrase during pool creation.
Remember it -- it unlocks your system at boot.

## Step 2: Create the dataset layout

Omarchy expects (but does not require) this dataset layout:

```
rpool/omarchy              (mountpoint=none, canmount=off)   -- container
rpool/omarchy/root         (mountpoint=/,    canmount=noauto) -- boot env
rpool/omarchy/varcache     (mountpoint=/var/cache, canmount=noauto)
rpool/omarchy/varlog       (mountpoint=/var/log,   canmount=noauto)
rpool/omarchy/home         (mountpoint=/home,      canmount=noauto)
rpool/keystore             (mountpoint=/etc/zfs/keys) -- optional
```

Create them:

```
zfs create -o mountpoint=none -o canmount=off rpool/omarchy
zfs create -o mountpoint=/ -o canmount=noauto rpool/omarchy/root
zfs create -o mountpoint=/var/cache -o canmount=noauto rpool/omarchy/varcache
zfs create -o mountpoint=/var/log   -o canmount=noauto rpool/omarchy/varlog
zfs create -o mountpoint=/home      -o canmount=noauto rpool/omarchy/home
```

Why separate datasets? When you take a snapshot of `rpool/omarchy/root`
and later roll back, child datasets (varcache, varlog, home) aren't
affected. That means:

- System rollback doesn't destroy your pacman cache (saves re-downloads)
- System rollback doesn't destroy your logs (keeps incident history)
- System rollback doesn't touch your home directory

## Step 3: Mount and bootstrap

```
mkdir -p /mnt
zfs mount rpool/omarchy/root        # mounts at /mnt if it's your altroot, else /
zfs mount rpool/omarchy/varcache
zfs mount rpool/omarchy/varlog
zfs mount rpool/omarchy/home

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
rpool/omarchy/varcache  /var/cache  zfs  defaults,zfsutil  0 0
rpool/omarchy/varlog    /var/log    zfs  defaults,zfsutil  0 0
rpool/omarchy/home      /home       zfs  defaults,zfsutil  0 0
EOF
```

### 4e. Set the zpool cachefile

```
zpool set cachefile=/etc/zfs/zpool.cache rpool
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
zfs set org.zfsbootmenu:commandline='quiet splash rw' rpool/omarchy/root
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
2. ZBM displays your boot environments (`rpool/omarchy/root` is the only
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
`rpool/omarchy` is separate from whatever your other OS uses
(`rpool/cachyos`, `rpool/ubuntu`, etc.).

### Isolation concerns

Both OSes share the same pool, so shared datasets like `rpool/home`
(mountpoint=/home, canmount=on) will auto-mount on both. That's usually
not what you want for initial testing -- it means Omarchy's hyprland
configs would leak into your other OS's home, or vice versa.

For fully isolated testing:

**1. Use a per-BE home dataset** (already in Step 2 above if you followed
Omarchy's layout).

**2. Tell `zfs-mount-generator` to skip `rpool/home` on Omarchy:**

```
zfs set org.openzfs.systemd:ignore=on rpool/home
```

This property only affects `zfs-mount-generator`. The other OS is
unaffected if it uses `zfs-mount.service` instead.

**3. Disable `zfs-mount.service` on Omarchy:**

```
systemctl disable zfs-mount.service
```

Why: `zfs-mount.service` runs `zfs mount -a` which mounts every
`canmount=on` dataset, including `rpool/home`. It does NOT respect the
`org.openzfs.systemd:ignore` property. With it disabled, Omarchy relies
entirely on `zfs-mount-generator` + fstab for mounts. The generator
handles shared datasets like `rpool/keystore`, `rpool/models`, etc.

### Cross-OS property visibility

`org.openzfs.systemd:ignore` is a ZFS property stored on the dataset,
visible to every OS that imports the pool. It's safe as long as the
other OS uses `zfs-mount.service` (which ignores the property). If the
other OS later switches to `zfs-mount-generator`, you'll need to revisit.

### Setting the default boot environment

ZBM's default boot is controlled by the pool's `bootfs` property:

```
# Keep the other OS as default:
zpool set bootfs=rpool/cachyos/root rpool

# Or make Omarchy default:
zpool set bootfs=rpool/omarchy/root rpool
```

Either way, both BEs show up in ZBM's menu at boot.

### Merging homes later

If you decide to merge `/home` across BEs (share media, dotfiles, etc.):

1. Copy `rpool/omarchy/home/<user>` contents into `rpool/home/<user>`
2. Delete or rename `rpool/omarchy/home`
3. Remove the `/home` fstab entry on Omarchy
4. Clear the ignore property: `zfs inherit org.openzfs.systemd:ignore rpool/home`
5. Re-enable `zfs-mount.service` on Omarchy

Consider a dotfile manager (chezmoi, stow) to keep OS-specific configs
layered on a shared home.

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

## Troubleshooting

**Double passphrase prompt at boot**
The initramfs key embedding didn't work. Check that
`/etc/mkinitcpio.conf.d/omarchy_zfs_keys.conf` contains
`FILES+=(/etc/zfs/keys/rpool.key)` (or your key path), then rebuild:
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
environment. Verify with `zfs get mountpoint rpool/omarchy/root`.

**`/home` mounts the wrong dataset (dual-boot)**
See [Appendix A](#appendix-a-dual-boot-alongside-an-existing-zfs-os) for
the `org.openzfs.systemd:ignore` + disable `zfs-mount.service` setup.

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
