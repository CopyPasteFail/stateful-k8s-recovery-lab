#!/usr/bin/env bash
# =============================================================================
# EXAMPLE ONLY — not used by the local demo
#
# LVM snapshot + Restic backup for self-managed nodes with LVM-backed PVCs.
#
# Requirements:
#   - Root or CAP_SYS_ADMIN + host /dev access to run lvcreate/mount/lvremove
#     (a standard Kubernetes pod cannot run this without elevated host access)
#   - The PVC must be backed by an LVM logical volume on this node
#   - RESTIC_PASSWORD must be set in the environment (do not hardcode)
#   - RESTIC_REPOSITORY must be set in the environment or overridden below
#
# Verify VG_NAME, LV_NAME, and MOUNT_POINT for your environment before running.
# Do NOT run this script in the local demo — it is for production nodes only.
#
# NODE PLACEMENT: this script must run on the specific node that owns the LVM
# logical volume backing the PVC. Use nodeName or nodeAffinity on the backup Job
# to pin it to the correct node. Running on the wrong node will fail at lvcreate
# because the LV will not be visible.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment or edit these defaults
# ---------------------------------------------------------------------------
VG_NAME="${VG_NAME:-vg0}"
LV_NAME="${LV_NAME:-leveldb-data}"
SNAPSHOT_NAME="${SNAPSHOT_NAME:-leveldb-restic-snap}"
SNAPSHOT_SIZE="${SNAPSHOT_SIZE:-50G}"    # COW region; must cover all writes during the backup window
MOUNT_POINT="${MOUNT_POINT:-/mnt/restic-source}"
# Path to the LevelDB data directory, relative to the snapshot mount root.
# Restic will back up: ${MOUNT_POINT}/${LEVELDB_PATH}
# Example: if the LV filesystem root contains a 'leveldb/' subdirectory,
# keep this as 'leveldb'. Do not use a leading slash.
LEVELDB_PATH="${LEVELDB_PATH:-leveldb}"
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:?RESTIC_REPOSITORY must be set}"
RESTIC_HOST="${RESTIC_HOST:-leveldb-app}"
RESTIC_TAG="${RESTIC_TAG:-leveldb-app}"

# RESTIC_PASSWORD must already be set in the environment — do not hardcode it here.
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD must be set}"

# ---------------------------------------------------------------------------
# State tracking
# ---------------------------------------------------------------------------

# Set to 1 only after lvcreate succeeds in THIS run.
# The cleanup trap only removes the snapshot LV if this script created it,
# preventing accidental removal of a pre-existing LV with the same name.
_snapshot_created=0

# ---------------------------------------------------------------------------
# Cleanup trap — runs on exit (normal or error) to unmount and remove snapshot
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?  # must be first — captures exit code before any other command
    set +e              # do not abort cleanup on errors; log and continue

    echo "[lvm-restic-backup] cleanup: starting"

    if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        echo "[lvm-restic-backup] cleanup: unmounting ${MOUNT_POINT}"
        umount "${MOUNT_POINT}" || echo "[lvm-restic-backup] WARNING: umount failed; manual cleanup required"
    fi

    # Only remove the snapshot LV if this script created it in this run.
    # This prevents removing a pre-existing LV that happens to share the name.
    if [[ "${_snapshot_created}" -eq 1 ]]; then
        if lvs "/dev/${VG_NAME}/${SNAPSHOT_NAME}" >/dev/null 2>&1; then
            echo "[lvm-restic-backup] cleanup: removing snapshot /dev/${VG_NAME}/${SNAPSHOT_NAME}"
            lvremove -f "/dev/${VG_NAME}/${SNAPSHOT_NAME}" || echo "[lvm-restic-backup] WARNING: lvremove failed; manual cleanup required"
        fi
    fi

    echo "[lvm-restic-backup] cleanup: done (exit code: ${exit_code})"
    exit "${exit_code}"
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

# OPTIONAL QUIESCE: LevelDB's WAL means the database can recover from a
# crash-consistent snapshot, so a hard quiesce is not strictly required.
# However, if the application exposes a checkpoint or flush endpoint, triggering
# it here reduces the number of WAL entries that need replaying on restore.
# Example (adapt to your app's health/admin API):
#   kubectl exec -n leveldb-system leveldb-app-0 -- /bin/leveldb-checkpoint || true
# Leave commented out unless your application supports it.

echo "[lvm-restic-backup] creating mount directory: ${MOUNT_POINT}"
mkdir -p "${MOUNT_POINT}"

echo "[lvm-restic-backup] creating LVM snapshot: /dev/${VG_NAME}/${SNAPSHOT_NAME} (COW size: ${SNAPSHOT_SIZE})"
lvcreate \
    --snapshot \
    --name "${SNAPSHOT_NAME}" \
    --size "${SNAPSHOT_SIZE}" \
    "/dev/${VG_NAME}/${LV_NAME}"
# Mark that this run owns the snapshot; cleanup will now remove it on exit.
_snapshot_created=1

echo "[lvm-restic-backup] mounting snapshot read-only at ${MOUNT_POINT}"
mount -o ro "/dev/${VG_NAME}/${SNAPSHOT_NAME}" "${MOUNT_POINT}"

echo "[lvm-restic-backup] starting Restic backup: ${MOUNT_POINT}/${LEVELDB_PATH}"
restic backup \
    "${MOUNT_POINT}/${LEVELDB_PATH}" \
    --host "${RESTIC_HOST}" \
    --tag "${RESTIC_TAG}" \
    --repo "${RESTIC_REPOSITORY}"

echo "[lvm-restic-backup] backup complete; cleanup will run on exit"
