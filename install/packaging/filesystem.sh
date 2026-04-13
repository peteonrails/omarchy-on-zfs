FS_TYPE=$(omarchy-fs-type)
FS_PKG_FILE="$OMARCHY_INSTALL/omarchy-fs-${FS_TYPE}.packages"

if [[ -f $FS_PKG_FILE ]]; then
  mapfile -t fs_packages < <(grep -v '^#' "$FS_PKG_FILE" | grep -v '^$')
  if (( ${#fs_packages[@]} > 0 )); then
    if [[ $FS_TYPE == "zfs" ]]; then
      omarchy-pkg-aur-add "${fs_packages[@]}"
    else
      omarchy-pkg-add "${fs_packages[@]}"
    fi
  fi
fi

# Create ZFS child datasets for /var/cache and /var/log so they're separate
# from the boot environment's snapshot scope. Without this, pacman cache and
# system logs would be rolled back when restoring a snapshot.
#
# This is only safe during a chroot install (OMARCHY_CHROOT_INSTALL=1) because
# on a live system journald and other services are writing to /var/log.
# For live installs, create these datasets manually before running omarchy,
# or snapshot/rollback support will include your logs and package cache.
if [[ $FS_TYPE == "zfs" && -n ${OMARCHY_CHROOT_INSTALL:-} ]]; then
  DATASET=$(zfs list -H -o name /)
  PARENT=$(dirname "$DATASET")

  for subvol in varcache:/var/cache varlog:/var/log; do
    name="${subvol%%:*}"
    mount_path="${subvol##*:}"
    target="$PARENT/$name"

    if ! zfs list "$target" &>/dev/null; then
      echo "Creating ZFS dataset $target for $mount_path"
      # Preserve any existing data while swapping the mount
      if [[ -d $mount_path ]] && compgen -G "$mount_path/*" >/dev/null; then
        sudo mv "$mount_path" "${mount_path}.omarchy-pre-zfs"
        sudo mkdir -p "$mount_path"
      fi
      sudo zfs create -o mountpoint="$mount_path" -o canmount=noauto "$target"
      sudo zfs mount "$target"
      if [[ -d "${mount_path}.omarchy-pre-zfs" ]]; then
        sudo cp -a "${mount_path}.omarchy-pre-zfs/." "$mount_path/"
        sudo rm -rf "${mount_path}.omarchy-pre-zfs"
      fi
    fi
  done
elif [[ $FS_TYPE == "zfs" ]]; then
  DATASET=$(zfs list -H -o name /)
  PARENT=$(dirname "$DATASET")
  for subvol in varcache varlog; do
    if ! zfs list "$PARENT/$subvol" &>/dev/null; then
      echo "NOTE: Consider creating $PARENT/$subvol dataset for proper snapshot isolation"
    fi
  done
fi
