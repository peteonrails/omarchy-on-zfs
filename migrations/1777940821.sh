echo "Install ZFS kernel compatibility guard (pacman hook + IgnorePkg)"

# Only applies to ZFS systems. No-op on btrfs.
if ! omarchy-fs-zfs; then
  exit 0
fi

# 1. Symlink the compat check into /usr/local/bin so the pacman hook can find
# it without relying on the user's PATH. The symlink target stays in
# ~/.local/share/omarchy/bin so omarchy-update bumps it transparently.
sudo install -d /usr/local/bin
sudo ln -sf "$OMARCHY_PATH/bin/omarchy-zfs-kernel-compat-check" /usr/local/bin/omarchy-zfs-kernel-compat-check

# 2. Install the pacman PreTransaction hook
sudo install -d /etc/pacman.d/hooks
sudo install -m 644 "$OMARCHY_PATH/default/pacman-hooks/90-omarchy-zfs-kernel-guard.hook" \
  /etc/pacman.d/hooks/90-omarchy-zfs-kernel-guard.hook

# 3. Pin linux + linux-headers in /etc/pacman.conf so users don't accidentally
# pull a kernel ahead of zfs-dkms. The hook above is the runtime safety net;
# this is the policy default. Bump the pin from a fork release when archzfs
# catches up.
if ! grep -qE '^IgnorePkg.*\blinux\b' /etc/pacman.conf; then
  if grep -qE '^#IgnorePkg' /etc/pacman.conf; then
    sudo sed -i 's|^#IgnorePkg.*|IgnorePkg = linux linux-headers|' /etc/pacman.conf
  else
    # Insert under [options] section
    sudo sed -i '/^\[options\]/a IgnorePkg = linux linux-headers' /etc/pacman.conf
  fi
fi

echo "Guard installed: kernel upgrades that would break ZFS now block at PreTransaction."
