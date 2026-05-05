echo "Configure archzfs repo as the ZFS package source"

if ! omarchy-fs-zfs; then
  exit 0
fi

bash "$OMARCHY_PATH/install/config/zfs-archzfs-repo.sh"
