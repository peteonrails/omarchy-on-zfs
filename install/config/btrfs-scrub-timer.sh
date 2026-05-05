# Install + enable the monthly btrfs scrub timer on btrfs systems.
# No-op on ZFS (the parallel zfs-scrub-timer.sh covers that).

if ! omarchy-fs-btrfs; then
  return 0 2>/dev/null || exit 0
fi

# Symlink the scrub helper into /usr/local/bin so the .service unit can
# reference an absolute, system-wide path that survives an omarchy-update.
sudo install -d /usr/local/bin
sudo ln -sf "$OMARCHY_PATH/bin/omarchy-btrfs-scrub" /usr/local/bin/omarchy-btrfs-scrub

# Install the systemd units
sudo install -m 644 "$OMARCHY_PATH/default/systemd/system/omarchy-btrfs-scrub.service" \
  /etc/systemd/system/omarchy-btrfs-scrub.service
sudo install -m 644 "$OMARCHY_PATH/default/systemd/system/omarchy-btrfs-scrub.timer" \
  /etc/systemd/system/omarchy-btrfs-scrub.timer

# Enable + start (running system) or just enable (chroot during install).
if [[ -d /run/systemd/system ]]; then
  sudo systemctl daemon-reload
  sudo systemctl enable --now omarchy-btrfs-scrub.timer
else
  sudo systemctl enable omarchy-btrfs-scrub.timer
fi
