echo "Install monthly ZFS scrub systemd timer"

if ! omarchy-fs-zfs; then
  exit 0
fi

bash "$OMARCHY_PATH/install/config/zfs-scrub-timer.sh"

# If the pool hasn't been scrubbed in over 60 days, kick one off now.
LAST=$(zpool status 2>/dev/null | grep -oE 'scrub repaired.*on [A-Za-z]+ [A-Za-z]+ +[0-9]+ [0-9:]+ [0-9]+' | tail -1 | grep -oE '[A-Za-z]+ +[0-9]+ [0-9:]+ [0-9]+$')
if [[ -n $LAST ]]; then
  last_ts=$(date -d "$LAST" +%s 2>/dev/null || echo 0)
  now_ts=$(date +%s)
  if (( now_ts - last_ts > 60 * 86400 )); then
    echo "Last scrub was $LAST — kicking off a fresh one in the background"
    sudo systemctl start omarchy-zfs-scrub.service || true
  fi
fi
