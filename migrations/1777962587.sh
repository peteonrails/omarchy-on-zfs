echo "Switch btrfs scrub from fork-shipped units to upstream btrfs-scrub@.timer"

if ! omarchy-fs-btrfs; then
  exit 0
fi

bash "$OMARCHY_PATH/install/config/btrfs-scrub-timer.sh"
