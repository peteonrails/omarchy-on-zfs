echo "Install monthly btrfs scrub systemd timer"

if ! omarchy-fs-btrfs; then
  exit 0
fi

bash "$OMARCHY_PATH/install/config/btrfs-scrub-timer.sh"
