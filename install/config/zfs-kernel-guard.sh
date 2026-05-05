# Install the ZFS kernel compatibility guard (pacman PreTransaction hook +
# IgnorePkg) so kernel upgrades that would break ZFS get blocked at the source.
# No-op on btrfs systems.

if ! omarchy-fs-zfs; then
  return 0 2>/dev/null || exit 0
fi

# Symlink the compat check into /usr/local/bin so the alpm hook can find it
sudo install -d /usr/local/bin
sudo ln -sf "$OMARCHY_PATH/bin/omarchy-zfs-kernel-compat-check" /usr/local/bin/omarchy-zfs-kernel-compat-check

# Install the pacman PreTransaction hook
sudo install -d /etc/pacman.d/hooks
sudo install -m 644 "$OMARCHY_PATH/default/pacman-hooks/90-omarchy-zfs-kernel-guard.hook" \
  /etc/pacman.d/hooks/90-omarchy-zfs-kernel-guard.hook

# Pin linux + linux-headers in /etc/pacman.conf — fork policy is to bump the
# kernel only when archzfs has a matching zfs-dkms.
if ! grep -qE '^IgnorePkg.*\blinux\b' /etc/pacman.conf; then
  if grep -qE '^#IgnorePkg' /etc/pacman.conf; then
    sudo sed -i 's|^#IgnorePkg.*|IgnorePkg = linux linux-headers|' /etc/pacman.conf
  else
    sudo sed -i '/^\[options\]/a IgnorePkg = linux linux-headers' /etc/pacman.conf
  fi
fi
