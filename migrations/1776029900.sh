echo "Configure ZFS boot environment if on ZFS root"

if omarchy-fs-zfs; then
  # Ensure ZFS packages are installed
  if omarchy-pkg-missing zfs-utils; then
    omarchy-pkg-aur-add zfs-utils zfs-dkms
  fi

  DATASET=$(zfs list -H -o name /)
  POOL=$(echo "$DATASET" | cut -d/ -f1)

  # Update mkinitcpio hooks if still using btrfs-overlayfs
  HOOKS_FILE=/etc/mkinitcpio.conf.d/omarchy_hooks.conf
  if [[ -f $HOOKS_FILE ]] && grep -q "btrfs-overlayfs" "$HOOKS_FILE"; then
    sudo tee "$HOOKS_FILE" <<EOF >/dev/null
HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block zfs filesystems fsck)
EOF
  fi

  # Ensure mountpoint and canmount are set for ZBM boot environment discovery
  [[ $(zfs get -H -o value mountpoint "$DATASET") != "/" ]] && sudo zfs set mountpoint=/ "$DATASET"
  [[ $(zfs get -H -o value canmount "$DATASET") != "noauto" ]] && sudo zfs set canmount=noauto "$DATASET"

  # Set ZBM kernel cmdline if not already set
  CURRENT_CMDLINE=$(zfs get -H -o value org.zfsbootmenu:commandline "$DATASET" 2>/dev/null)
  if [[ $CURRENT_CMDLINE == "-" || -z $CURRENT_CMDLINE ]]; then
    sudo zfs set "org.zfsbootmenu:commandline=quiet splash rw" "$DATASET"
  fi

  # Ensure zpool cachefile is set so initramfs can import the pool
  if [[ ! -s /etc/zfs/zpool.cache ]]; then
    sudo mkdir -p /etc/zfs
    sudo zpool set cachefile=/etc/zfs/zpool.cache "$POOL"
  fi

  # Embed encryption key in initramfs to avoid double-prompt at boot
  ENCROOT=$(zfs get -H -o value encryptionroot "$DATASET" 2>/dev/null)
  if [[ $ENCROOT != "-" ]]; then
    KEYLOC=$(zfs get -H -o value keylocation "$ENCROOT" 2>/dev/null)
    if [[ $KEYLOC == file://* ]]; then
      KEYFILE="${KEYLOC#file://}"
      if [[ -r $KEYFILE ]] && ! grep -q "FILES.*$KEYFILE" /etc/mkinitcpio.conf.d/omarchy_zfs_keys.conf 2>/dev/null; then
        echo "Embedding ZFS encryption key in initramfs"
        sudo tee /etc/mkinitcpio.conf.d/omarchy_zfs_keys.conf >/dev/null <<EOF
FILES+=($KEYFILE)
EOF
      fi

      # Sync user password with ZFS passphrase if available
      KEYFORMAT=$(zfs get -H -o value keyformat "$ENCROOT" 2>/dev/null)
      if [[ -r $KEYFILE && $KEYFORMAT == "passphrase" ]]; then
        # Only set if user hasn't set their own password (empty or not set)
        if sudo passwd -S "$USER" 2>/dev/null | awk '{print $2}' | grep -qE '^(NP|L)$'; then
          echo "Syncing user password with ZFS encryption passphrase"
          ZFS_PASS=$(sudo cat "$KEYFILE")
          echo "$USER:$ZFS_PASS" | sudo chpasswd
        fi
      fi
    fi
  fi

  # Rebuild initramfs to pick up any changes
  sudo mkinitcpio -P
fi
