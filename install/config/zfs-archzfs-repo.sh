# Ensure a ZFS package source is configured on /etc/pacman.conf so users get
# zfs-dkms / zfs-utils updates. The omarchy-on-zfs fork ships archzfs as the
# default canonical source. No-op on:
#   - btrfs systems
#   - systems that already have archzfs, cachyos, or chaotic-aur configured
#     (any of these provides zfs-dkms)

if ! omarchy-fs-zfs; then
  return 0 2>/dev/null || exit 0
fi

# Already have a ZFS-providing repo? Leave it alone.
if grep -qE '^\[(archzfs|cachyos|cachyos-v3|cachyos-v4|chaotic-aur)\]' /etc/pacman.conf; then
  return 0 2>/dev/null || exit 0
fi

ARCHZFS_KEY="DDF7DB817396A49B2A2723F7403BD972F75D9D76"

echo "Configuring archzfs repo (ZFS package source)..."

# Trust the archzfs signing key
if ! sudo pacman-key --list-keys "$ARCHZFS_KEY" &>/dev/null; then
  sudo pacman-key --recv-keys "$ARCHZFS_KEY"
  sudo pacman-key --lsign-key "$ARCHZFS_KEY"
fi

# Append the repo. Use single quotes so $repo / $arch reach pacman literally.
sudo tee -a /etc/pacman.conf >/dev/null <<'EOF'

# Added by omarchy-on-zfs — canonical ZFS package source
[archzfs]
Server = https://archzfs.com/$repo/$arch
EOF

# Refresh sync DBs so the new repo is queryable immediately
sudo pacman -Sy
