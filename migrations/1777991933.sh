echo "Clean up stale omarchy-snapshot snapshots on auto-snapshot=false datasets (e.g. swap zvols)"

if ! omarchy-fs-zfs; then
  exit 0
fi

# Find datasets marked com.sun:auto-snapshot=false. Prior versions of
# omarchy-snapshot used `zfs snapshot -r` which ignored that property and
# created useless snapshots on swap zvols on every system update.
mapfile -t EXCLUDED < <(
  sudo zfs list -H -o name,com.sun:auto-snapshot -t filesystem,volume 2>/dev/null | \
    awk '$2 == "false" {print $1}'
)

if (( ${#EXCLUDED[@]} == 0 )); then
  exit 0
fi

# Destroy only snapshots matching omarchy-snapshot's naming pattern
# (YYYYMMDD-HHMMSS_*) so we don't touch any user-created snapshots.
for ds in "${EXCLUDED[@]}"; do
  mapfile -t SNAPS < <(sudo zfs list -H -o name -t snapshot -d 1 "$ds" 2>/dev/null)
  for snap in "${SNAPS[@]}"; do
    snap_tail="${snap#*@}"
    if [[ $snap_tail =~ ^[0-9]{8}-[0-9]{6}_ ]]; then
      echo "Destroying stale snapshot: $snap"
      sudo zfs destroy "$snap" || true
    fi
  done
done
