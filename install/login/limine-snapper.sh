if omarchy-fs-zfs; then
  # ZFS boot environment setup -- ZBM is managed by the user externally
  sudo tee /etc/mkinitcpio.conf.d/omarchy_hooks.conf <<EOF >/dev/null
HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block zfs filesystems fsck)
EOF

  sudo tee /etc/mkinitcpio.conf.d/thunderbolt_module.conf <<EOF >/dev/null
MODULES+=(thunderbolt)
EOF

  # Configure this dataset as a ZBM boot environment
  DATASET=$(zfs list -H -o name /)
  POOL=$(echo "$DATASET" | cut -d/ -f1)

  # Set mountpoint=/ and canmount=noauto so ZBM discovers this as a boot environment
  sudo zfs set mountpoint=/ "$DATASET"
  sudo zfs set canmount=noauto "$DATASET"

  # Set kernel cmdline if not already set (inherit from pool if possible)
  CURRENT_CMDLINE=$(zfs get -H -o value org.zfsbootmenu:commandline "$DATASET" 2>/dev/null)
  if [[ $CURRENT_CMDLINE == "-" || -z $CURRENT_CMDLINE ]]; then
    sudo zfs set "org.zfsbootmenu:commandline=quiet splash rw" "$DATASET"
  fi

  # Ensure zpool cachefile is set so initramfs can import the pool without probing
  if [[ ! -s /etc/zfs/zpool.cache ]]; then
    sudo mkdir -p /etc/zfs
    sudo zpool set cachefile=/etc/zfs/zpool.cache "$POOL"
  fi

  # Set up zfs-mount-generator: creates systemd mount units from a cache file
  # that zfs-zed keeps in sync with dataset properties. This is the modern
  # alternative to zfs-mount.service's `zfs mount -a` approach and integrates
  # cleanly with systemd's boot sequence.
  sudo mkdir -p /etc/zfs/zfs-list.cache
  if [[ ! -f /etc/zfs/zfs-list.cache/$POOL ]]; then
    # Seed the cache with current dataset properties. zfs-zed will keep it
    # updated going forward via the history_event-zfs-list-cacher.sh hook.
    ZFS_CACHE_PROPS="name,mountpoint,canmount,atime,relatime,devices,exec,readonly,setuid,nbmand,encroot,keylocation,org.openzfs.systemd:requires,org.openzfs.systemd:requires-mounts-for,org.openzfs.systemd:before,org.openzfs.systemd:after,org.openzfs.systemd:wanted-by,org.openzfs.systemd:required-by,org.openzfs.systemd:nofail,org.openzfs.systemd:ignore"
    sudo zfs list -H -t filesystem -o "$ZFS_CACHE_PROPS" -r "$POOL" | sort | sudo tee "/etc/zfs/zfs-list.cache/$POOL" >/dev/null
  fi

  # Enable zfs-zed so dataset property changes keep the cache file current
  chrootable_systemctl_enable zfs-zed.service

  # Install omarchy ZBM branding hooks (Tokyo Night menu theme + branded
  # passphrase prompt). These only take effect once ZBM is rebuilt via
  # `generate-zbm`, which we run below if the tool is available.
  sudo mkdir -p /etc/zfsbootmenu/hooks/setup.d /etc/zfsbootmenu/hooks/load-key.d
  sudo install -m 755 "$OMARCHY_PATH/default/zfsbootmenu/hooks/setup.d/01-omarchy-theme.sh" /etc/zfsbootmenu/hooks/setup.d/
  sudo install -m 755 "$OMARCHY_PATH/default/zfsbootmenu/hooks/load-key.d/01-omarchy-unlock.sh" /etc/zfsbootmenu/hooks/load-key.d/

  # Embed the encryption key in the initramfs (via FILES=) so the initramfs can
  # unlock the pool without double-prompting. The key file lives in the keysource
  # dataset which has the same encryption root, so it's accessible once the pool
  # has been unlocked by ZBM. FILES= copies its contents into the initramfs image.
  ENCROOT=$(zfs get -H -o value encryptionroot "$DATASET" 2>/dev/null)
  if [[ $ENCROOT != "-" ]]; then
    KEYLOC=$(zfs get -H -o value keylocation "$ENCROOT" 2>/dev/null)
    if [[ $KEYLOC == file://* ]]; then
      KEYFILE="${KEYLOC#file://}"
      if [[ -r $KEYFILE ]]; then
        echo "Embedding encryption key in initramfs: $KEYFILE"
        sudo tee /etc/mkinitcpio.conf.d/omarchy_zfs_keys.conf >/dev/null <<EOF
FILES+=($KEYFILE)
EOF
      fi

      # Fix zfs-mount-generator dependency cycle on the keystore dataset.
      #
      # When the pool's key file lives inside a dataset on the same pool
      # (e.g., rpool/keystore mounted at /etc/zfs/keys holds rpool.key),
      # zfs-mount-generator creates a mount unit with:
      #   After=zfs-load-key@rpool.service
      #   BindsTo=zfs-load-key@rpool.service
      #
      # But zfs-load-key@rpool.service has RequiresMountsFor=/etc/zfs/keys/rpool.key,
      # which adds After=etc-zfs-keys.mount — creating a cycle.
      #
      # Since the key is embedded in the initramfs (above), zfs-load-key@rpool
      # is a no-op at userspace. Ship a static mount unit that drops the
      # circular dependency. Drop-ins can't reset After=/BindsTo=, so we
      # replace the generated unit entirely.
      KEYDIR=$(dirname "$KEYFILE")
      KEYSTORE_DS=$(zfs list -H -o name,mountpoint -r "$POOL" 2>/dev/null | awk -v mp="$KEYDIR" '$2 == mp {print $1}')
      if [[ -n $KEYSTORE_DS ]]; then
        MOUNT_UNIT_NAME=$(systemd-escape --path "$KEYDIR").mount
        echo "Installing static mount unit for $KEYSTORE_DS to break generator cycle"
        sudo tee "/etc/systemd/system/$MOUNT_UNIT_NAME" >/dev/null <<UNIT
# Static override for $KEYSTORE_DS — breaks the zfs-mount-generator
# dependency cycle between this mount and zfs-load-key@${POOL}.service.
# The pool key is loaded from initramfs, so the load-key dep is not needed.

[Unit]
Description=Mount $KEYSTORE_DS at $KEYDIR
Documentation=man:zfs-mount-generator(8)
DefaultDependencies=no
Before=local-fs.target
After=zfs-import.target
RequiresMountsFor=$(dirname "$KEYDIR")

[Mount]
Where=$KEYDIR
What=$KEYSTORE_DS
Type=zfs
Options=defaults,atime,relatime,nodev,exec,rw,suid,nomand,zfsutil

[Install]
WantedBy=local-fs.target
UNIT
        sudo systemctl daemon-reload
        chrootable_systemctl_enable "$MOUNT_UNIT_NAME"
      fi

      # Sync the user's login password with the ZFS encryption passphrase
      # so they only need to remember one password (mirrors btrfs/LUKS behavior)
      KEYFORMAT=$(zfs get -H -o value keyformat "$ENCROOT" 2>/dev/null)
      if [[ -z ${OMARCHY_CHROOT_INSTALL:-} && -r $KEYFILE && $KEYFORMAT == "passphrase" ]]; then
        echo "Syncing user password with ZFS encryption passphrase"
        ZFS_PASS=$(sudo cat "$KEYFILE")
        echo "$USER:$ZFS_PASS" | sudo chpasswd
      fi
    fi
  fi

elif command -v limine &>/dev/null; then
  sudo pacman -S --noconfirm --needed limine-snapper-sync limine-mkinitcpio-hook

  sudo tee /etc/mkinitcpio.conf.d/omarchy_hooks.conf <<EOF >/dev/null
HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs)
EOF
  sudo tee /etc/mkinitcpio.conf.d/thunderbolt_module.conf <<EOF >/dev/null
MODULES+=(thunderbolt)
EOF

  # Detect boot mode
  [[ -d /sys/firmware/efi ]] && EFI=true

  # Find config location
  if [[ -f /boot/EFI/arch-limine/limine.conf ]]; then
    limine_config="/boot/EFI/arch-limine/limine.conf"
  elif [[ -f /boot/EFI/BOOT/limine.conf ]]; then
    limine_config="/boot/EFI/BOOT/limine.conf"
  elif [[ -f /boot/EFI/limine/limine.conf ]]; then
    limine_config="/boot/EFI/limine/limine.conf"
  elif [[ -f /boot/limine/limine.conf ]]; then
    limine_config="/boot/limine/limine.conf"
  elif [[ -f /boot/limine.conf ]]; then
    limine_config="/boot/limine.conf"
  else
    echo "Error: Limine config not found" >&2
    exit 1
  fi

  CMDLINE=$(grep "^[[:space:]]*cmdline:" "$limine_config" | head -1 | sed 's/^[[:space:]]*cmdline:[[:space:]]*//')

  sudo cp $OMARCHY_PATH/default/limine/default.conf /etc/default/limine
  sudo sed -i "s|@@CMDLINE@@|$CMDLINE|g" /etc/default/limine

  # Append any drop-in kernel cmdline configs (from hardware fix scripts, etc.)
  for dropin in /etc/limine-entry-tool.d/*.conf; do
    [ -f "$dropin" ] && cat "$dropin" | sudo tee -a /etc/default/limine >/dev/null
  done

  # UKI and EFI fallback are EFI only
  if [[ -z $EFI ]]; then
    sudo sed -i '/^ENABLE_UKI=/d; /^ENABLE_LIMINE_FALLBACK=/d' /etc/default/limine
  fi

  # Remove the original config file if it's not /boot/limine.conf
  if [[ $limine_config != "/boot/limine.conf" ]] && [[ -f $limine_config ]]; then
    sudo rm "$limine_config"
  fi

  # We overwrite the whole thing knowing the limine-update will add the entries for us
  sudo cp $OMARCHY_PATH/default/limine/limine.conf /boot/limine.conf

  # Match Snapper configs if not installing from the ISO
  if [[ -z ${OMARCHY_CHROOT_INSTALL:-} ]]; then
    if ! sudo snapper list-configs 2>/dev/null | grep -q "root"; then
      sudo snapper -c root create-config /
    fi

    if ! sudo snapper list-configs 2>/dev/null | grep -q "home"; then
      sudo snapper -c home create-config /home
    fi
  fi

  # Enable quota to allow space-aware algorithms to work
  sudo btrfs quota enable /

  # Tweak default Snapper configs
  sudo sed -i 's/^TIMELINE_CREATE="yes"/TIMELINE_CREATE="no"/' /etc/snapper/configs/{root,home}
  sudo sed -i 's/^NUMBER_LIMIT="50"/NUMBER_LIMIT="5"/' /etc/snapper/configs/{root,home}
  sudo sed -i 's/^NUMBER_LIMIT_IMPORTANT="10"/NUMBER_LIMIT_IMPORTANT="5"/' /etc/snapper/configs/{root,home}
  sudo sed -i 's/^SPACE_LIMIT="0.5"/SPACE_LIMIT="0.3"/' /etc/snapper/configs/{root,home}
  sudo sed -i 's/^FREE_LIMIT="0.2"/FREE_LIMIT="0.3"/' /etc/snapper/configs/{root,home}

  chrootable_systemctl_enable limine-snapper-sync.service
fi

echo "Re-enabling mkinitcpio hooks..."

# Restore the specific mkinitcpio pacman hooks
if [[ -f /usr/share/libalpm/hooks/90-mkinitcpio-install.hook.disabled ]]; then
  sudo mv /usr/share/libalpm/hooks/90-mkinitcpio-install.hook.disabled /usr/share/libalpm/hooks/90-mkinitcpio-install.hook
fi

if [[ -f /usr/share/libalpm/hooks/60-mkinitcpio-remove.hook.disabled ]]; then
  sudo mv /usr/share/libalpm/hooks/60-mkinitcpio-remove.hook.disabled /usr/share/libalpm/hooks/60-mkinitcpio-remove.hook
fi

echo "mkinitcpio hooks re-enabled"

if omarchy-fs-zfs; then
  # Rebuild initramfs for ZFS
  sudo mkinitcpio -P

  # Regenerate ZBM if available (user may manage it externally)
  if command -v generate-zbm &>/dev/null; then
    sudo generate-zbm
  fi
else
  sudo limine-update

  # Verify that limine-update actually added boot entries
  if ! grep -q "^/+" /boot/limine.conf; then
    echo "Error: limine-update failed to add boot entries to /boot/limine.conf" >&2
    exit 1
  fi

  if [[ -n $EFI ]] && efibootmgr &>/dev/null; then
    # Remove the archinstall-created Limine entry
    while IFS= read -r bootnum; do
      sudo efibootmgr -b "$bootnum" -B >/dev/null 2>&1
    done < <(efibootmgr | grep -E "^Boot[0-9]{4}\*? Arch Linux Limine" | sed 's/^Boot\([0-9]\{4\}\).*/\1/')
  fi
fi
