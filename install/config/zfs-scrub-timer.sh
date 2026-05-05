# Install + enable the monthly ZFS scrub timer on ZFS systems.
# No-op on btrfs (snapper covers their world).

if ! omarchy-fs-zfs; then
  return 0 2>/dev/null || exit 0
fi

# Symlink the scrub helper into /usr/local/bin so the .service unit can
# reference an absolute, system-wide path that survives an omarchy-update.
sudo install -d /usr/local/bin
sudo ln -sf "$OMARCHY_PATH/bin/omarchy-zfs-scrub" /usr/local/bin/omarchy-zfs-scrub

# Install the systemd units
sudo install -m 644 "$OMARCHY_PATH/default/systemd/system/omarchy-zfs-scrub.service" \
  /etc/systemd/system/omarchy-zfs-scrub.service
sudo install -m 644 "$OMARCHY_PATH/default/systemd/system/omarchy-zfs-scrub.timer" \
  /etc/systemd/system/omarchy-zfs-scrub.timer

# Enable + start (running system) or just enable (chroot during install).
if [[ -d /run/systemd/system ]]; then
  sudo systemctl daemon-reload
  sudo systemctl enable --now omarchy-zfs-scrub.timer
else
  sudo systemctl enable omarchy-zfs-scrub.timer
fi
