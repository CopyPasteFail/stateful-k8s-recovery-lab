# Production Snapshots

This document covers the consistency boundary between the local demo backup and a production Restic backup, and provides concrete guidance for two production approaches: LVM snapshots and CSI VolumeSnapshots.

---

## Why the consistency boundary matters

### Local demo

The backup CronJob mounts the live PVC read-only and runs Restic against the active LevelDB directory while the app is writing. LevelDB's write-ahead log (WAL) means the database can recover from a crash-consistent state, but Restic reading a live directory does not guarantee it captures a point-in-time consistent view — it may read some files before and some after a given write.

**Acceptable for:** workflow testing, learning the toolchain, smoke testing.  
**Not acceptable for:** production use where data loss or backup-time corruption is not tolerable.

### Production

Restic should read from a crash-consistent snapshot source, not the live PVC. The app continues running against the original volume; the snapshot captures a stable point in time that Restic reads without racing against live writes.

Two paths exist depending on your infrastructure:

| Path | When to use |
|---|---|
| LVM snapshot | Self-managed nodes or bare metal with LVM-backed PVCs |
| CSI VolumeSnapshot | Managed Kubernetes with a CSI driver that supports snapshots (preferred) |

---

## Path 1: LVM snapshot

### How it works

This path requires a backup container with elevated host-level access (root or `CAP_SYS_ADMIN` plus host `/dev` access). A standard unprivileged Kubernetes pod cannot create LVM snapshots or mount block devices. See [Requirements and risks](#requirements-and-risks) below before proceeding.

1. `lvcreate --snapshot` creates a copy-on-write snapshot of the logical volume backing the PVC. This completes in milliseconds regardless of dataset size.
2. The snapshot LV is mounted read-only to a temporary path inside the backup container.
3. Restic reads from the snapshot mount. The app continues writing to the original volume and is unaffected.
4. After Restic completes, unmount the snapshot and `lvremove` it.

### High-level flow

```bash
lvcreate --snapshot --name <snapshot_name> --size <cow_size> /dev/<vg>/<lv>
mount -o ro /dev/<vg>/<snapshot_name> /mnt/restic-source
restic backup /mnt/restic-source/leveldb --host leveldb-app --tag leveldb-app
umount /mnt/restic-source
lvremove -f /dev/<vg>/<snapshot_name>
```

See [`scripts/examples/lvm-restic-backup.sh`](../scripts/examples/lvm-restic-backup.sh) for a parameterized example with a cleanup trap for abnormal exits.

### Requirements and risks

- **Host/device access:** the backup Job needs access to LVM device nodes on the host. This requires elevated privileges or a host-path volume for `/dev`. Isolate this with a dedicated service account and a minimal image — do not use a general-purpose container image with unnecessary capabilities.
- **Node affinity:** the Job must run on the same node as the PVC. Add a `nodeName` or `nodeAffinity` rule to the Job spec to pin it.
- **Cleanup on failure:** if the backup Job exits abnormally, the snapshot LV and mount may be left behind. Use a cleanup trap (as shown in the example script) and monitor for orphaned snapshots with `lvs`.
- **COW size:** the snapshot's copy-on-write region must be large enough to hold all writes that occur during the backup window. For a 2 TB dataset with a high write rate, allocate generously. A snapshot that exhausts its COW space becomes invalid mid-backup. Check `lvs -o lv_snapshot_invalid` to detect this.

---

## Path 2: CSI VolumeSnapshot

### How it works

The CSI driver creates a volume snapshot at the storage-provider layer. The snapshot is then bound to a temporary restore-mode PVC that the Restic backup Job mounts as a read-only source.

1. Create a `VolumeSnapshot` referencing the app's PVC and a `VolumeSnapshotClass` for your driver.
2. Wait for the snapshot `readyToUse: true`.
3. Create a temporary PVC with `dataSource` pointing to the `VolumeSnapshot`.
4. Run the Restic backup Job with the temporary PVC explicitly mounted read-only. The PVC is not attached to any pod automatically — the Job spec must include a `volumes` entry referencing it and a `volumeMounts` entry in the container.
5. Delete the temporary PVC and the `VolumeSnapshot` after backup completes.

See [`examples/csi-volumesnapshot.yaml`](../examples/csi-volumesnapshot.yaml) for example manifests covering steps 1–3. Step 4 (the backup Job) uses the same Job structure as the existing CronJob but reads from the snapshot PVC instead of the live PVC.

### Requirements

- A CSI driver that supports the `VolumeSnapshot` API — for example, the AWS EBS CSI driver, GCP PD CSI driver, Azure Disk CSI driver, or Longhorn.
- A `VolumeSnapshotClass` configured for your driver. The exact name and parameters vary by cloud provider and driver version.
- RBAC for the backup Job or controller to create and delete `VolumeSnapshot` and `PersistentVolumeClaim` objects in the target namespace.

### Why CSI is preferred on managed Kubernetes

CSI snapshots are created at the storage-provider level and do not require privileged node access or LVM tooling. The backup Job reads a standard PVC rather than a raw device mount, which is simpler to operate, avoids node affinity pinning, and integrates with provider-level snapshot retention and lifecycle policies.

---

## Choosing between the two paths

| Concern | LVM snapshot | CSI VolumeSnapshot |
|---|---|---|
| Requires LVM on nodes | Yes | No |
| Requires privileged node access | Yes | No |
| Works on managed Kubernetes | Only if nodes use LVM | Yes (driver-dependent) |
| Snapshot creation time | Milliseconds | Provider-dependent (typically seconds) |
| COW size must be managed | Yes | No |
| Node affinity required | Yes | No |
| Preferred for new production deployments | No | Yes |

---

## Related

- [docs/backup-restore.md — Consistency boundary](backup-restore.md#consistency-boundary)
- [docs/tradeoffs.md — Backup consistency](tradeoffs.md#consistency)
- [scripts/examples/lvm-restic-backup.sh](../scripts/examples/lvm-restic-backup.sh)
- [examples/csi-volumesnapshot.yaml](../examples/csi-volumesnapshot.yaml)
