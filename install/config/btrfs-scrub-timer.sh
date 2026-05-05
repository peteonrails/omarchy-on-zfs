# Enable monthly btrfs scrub on root using btrfs-progs's btrfs-scrub@.timer
# template (already shipped by stock Arch — no fork-shipped units needed).
# No-op on ZFS systems.
#
# Idempotent: also cleans up the hand-rolled units shipped in v3.7.1-zfs.3
# if they're still present from an earlier update.

if ! omarchy-fs-btrfs; then
  return 0 2>/dev/null || exit 0
fi

# Cleanup leftovers from v3.7.1-zfs.3's hand-rolled approach (no-op if absent)
if [[ -f /etc/systemd/system/omarchy-btrfs-scrub.timer ]]; then
  sudo systemctl disable --now omarchy-btrfs-scrub.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/omarchy-btrfs-scrub.service \
             /etc/systemd/system/omarchy-btrfs-scrub.timer
  sudo rm -f /usr/local/bin/omarchy-btrfs-scrub
  sudo systemctl daemon-reload
fi

# Enable the upstream-shipped template for "/" (the "-" instance is
# systemd-escape for the "/" mountpoint).
if [[ -d /run/systemd/system ]]; then
  sudo systemctl daemon-reload
  sudo systemctl enable --now btrfs-scrub@-.timer
else
  sudo systemctl enable btrfs-scrub@-.timer
fi
