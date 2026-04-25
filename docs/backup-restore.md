# Backup and Restore

This document covers the backup and restore design, the operator procedures, and the rationale for each decision.

---

## Table of contents

1. [Design goals](#design-goals)
2. [RPO and RTO](#rpo-and-rto)
3. [Backup design](#backup-design)
4. [Consistency boundary](#consistency-boundary)
5. [Backup operator procedure](#backup-operator-procedure)
6. [Restore design](#restore-design)
7. [Restore operator procedure](#restore-operator-procedure)
8. [Restore failure recovery](#restore-failure-recovery)
9. [Restic repository management](#restic-repository-management)
10. [MinIO configuration](#minio-configuration)
11. [Production hardening](#production-hardening)

---

## Design goals

- A backup should require no manual steps under normal operation
- A restore should require a single command under normal operation and leave the system in a known state whether it succeeds or fails
- The backup and restore workflow should be exercisable on a laptop with no external dependencies
- Production scale (2 TB per pod) is supported by the same core design. The local POC and production share the same operational workflow: a scheduled Kubernetes CronJob, a manual one-off backup trigger, Restic as the backup engine, an S3-compatible backend, the same restore flow, and the same monitoring and alerting. Where they differ: the consistency boundary (live directory vs. LVM or CSI snapshot), the object storage backend (in-cluster MinIO vs. durable external storage), real node storage and larger datasets, stricter IAM, secrets management, and networking, and regular retention policy review and restore drills

---

## RPO and RTO

**RPO — Recovery Point Objective:** The maximum age of the most recent recoverable backup.

This system targets a **six-hour RPO**. The backup CronJob fires every six hours. If a CronJob run fails, the Prometheus alert `LevelDBBackupNotRunRecently` fires after eight hours (2x the interval), giving one retry window before alerting.

An RPO of six hours means: in the worst case, a full system failure immediately before a scheduled backup would lose up to six hours of writes.

**RTO — Recovery Time Objective:** The time required to restore service after a failure.

RTO is not bounded by this system's design. It depends on:
- The size of the dataset being restored
- The throughput of the storage medium (PVC write speed)
- The network bandwidth from MinIO (or remote object storage in production)
- The time to restart the application and warm its caches

For a 2 TB dataset at 200 MB/s I/O throughput, the restore transfer alone takes approximately 3 hours. Test and document the RTO for each production deployment separately. Do not assume a six-hour RPO implies a six-hour RTO.

---

## Backup design

### CronJob schedule

```yaml
schedule: "0 */6 * * *"    # every 6 hours at the top of the hour
concurrencyPolicy: Forbid   # do not start a new Job if one is already running
```

`concurrencyPolicy: Forbid` keeps backup execution predictable. Restic uses repository-level locking, so a second concurrent Job will contend on that lock and either fail or stall waiting for it. Overlapping Jobs also create compounding operational problems: ambiguous backup status, extra I/O pressure on the PVC or snapshot, and doubled object-store bandwidth at the same time. Skipping a scheduled run when a Job is already in progress is the correct behavior.

### Restic

Restic is an open-source backup tool with native support for S3-compatible backends, AES-256-CTR encryption, content-defined chunking, and deduplication. These properties make it appropriate for large, frequently-changing datasets.

- **Encryption:** every snapshot is encrypted with the Restic repository password before it leaves the pod. MinIO holds only ciphertext.
- **Deduplication:** Restic computes a rolling hash over the data stream. Unchanged chunks are referenced, not re-uploaded. A six-hour incremental backup of a dataset with a low change rate (e.g., 10 GB changed out of 2 TB) transfers only the changed chunks plus metadata.
- **Integrity checking:** `restic check` verifies the repository index. The local demo backup Job does not run `restic check` after every snapshot — it runs `restic init` (idempotent), `restic backup`, and `restic snapshots`. For production, schedule periodic `restic check` runs separately from the six-hour backup path.

### What is backed up

The CronJob mounts the app PVC (the `/data/leveldb` directory) and runs:

```bash
restic backup /backup-source/leveldb --tag leveldb-app --host leveldb-app
```

Tags allow filtering snapshots by source in `restic snapshots`.

### Stable host identity

The backup Job passes `--host "${RESTIC_HOST}"` (default: `leveldb-app`) to every `restic backup` invocation. This matters because Kubernetes assigns a new random pod name to every Job run. Without an explicit `--host`, Restic records the pod name as the snapshot host. On the next run it sees a different host name, cannot find a parent snapshot for the same dataset, and falls back to scanning every file—producing the log message `no parent snapshot found, will read all files`. For a 2 TB dataset on a six-hour cycle this is a significant performance penalty.

With a fixed host name, Restic finds the previous snapshot for `leveldb-app`, computes a diff, and uploads only changed chunks. Set `backup.restic.host` in Helm values to override the default.

### Retention policy

The local demo backup Job does not run `restic forget --prune`. Snapshots accumulate in the repository until manually pruned. For production, add a `restic forget --prune` step to the backup Job (or a separate scheduled Job) with a policy appropriate for your storage capacity and compliance requirements. Example policy:

```
--keep-hourly 24    # keep last 24 hourly snapshots
--keep-daily 7      # keep last 7 daily snapshots
--keep-weekly 4     # keep last 4 weekly snapshots
```

Without pruning, the Restic repository grows without bound. Add retention pruning before going to production.

---

## Consistency boundary

The local POC and production share the same operational workflow. The consistency boundary is where they diverge most significantly at the technical level.

### Local POC

The CronJob mounts the live PVC read-only at `/backup-source` and runs Restic against `/backup-source/leveldb` while the app is running. LevelDB is not paused. The risk of catching a torn write is low for a development demo with small datasets, but it is not zero.

**Acceptable for:** exercising the operational workflow, learning the toolchain, smoke testing.
**Not acceptable for:** production use with data you cannot afford to lose or corrupt.

### Production design

LevelDB maintains its own internal consistency using a write-ahead log (WAL) and compaction. However, Restic reading the directory while LevelDB is writing does not guarantee that Restic captures a point-in-time consistent snapshot—it may read some files before and some files after a given write.

The production approach is:

1. **LVM snapshot** — the underlying logical volume is snapshotted using `lvcreate --snapshot`. LVM snapshots are copy-on-write and complete in milliseconds regardless of dataset size. The running LevelDB process continues writing to the original volume. The snapshot captures a crash-consistent point in time.
2. **Mount the snapshot** — the snapshot LV is mounted read-only to a temporary path (e.g., `/mnt/restic-source`).
3. **Restic backup** — runs against `/mnt/restic-source/leveldb`. The app is unaffected.
4. **Cleanup** — unmount and `lvremove` the snapshot after Restic completes.

This requires:
- The PVC to be backed by an LVM logical volume on the node
- The backup Job to have host-path or device access to the LVM tooling
- OR a CSI driver that supports volume snapshots (e.g., the AWS EBS CSI driver), which can replace LVM with a cloud-native snapshot

Using a CSI volume snapshot is the preferred production path on managed Kubernetes. The CSI driver creates the snapshot; Restic reads from the snapshot's bound PVC.

For concrete examples of both paths — including a parameterized LVM script and CSI manifest — see [docs/production-snapshots.md](production-snapshots.md).

---

## Backup operator procedure

**Check that backups are running:**

```bash
make backup-status
```

**Trigger a manual backup:**

```bash
make backup
```

`scripts/backup.sh` checks whether a backup Job is already running. If one is, it exits with a warning rather than creating a concurrent Job. If no Job is running, it creates a one-off Job from the CronJob spec using:

```bash
kubectl create job --from=cronjob/leveldb-app-backup leveldb-app-backup-manual-$(date +%s) -n leveldb-system
```

**Suspend the scheduled CronJob:**

```bash
make suspend-backups
```

Sets `spec.suspend: true` on the CronJob. Any Job already running continues to completion.

**Resume the scheduled CronJob:**

```bash
make resume-backups
```

Sets `spec.suspend: false`.

---

## Restore design

The restore procedure has six required steps. If any step fails, the procedure halts and prints recovery instructions. It does not attempt to roll back partial changes automatically, because partial rollbacks can themselves fail.

### Step 1: Suspend the CronJob

Prevent new backup Jobs from starting while the PVC is being modified.

### Step 2: Guard against a running backup Job

If a backup Job is currently running, the script exits with a warning and instructs the operator to wait. Do not interrupt a running backup—Restic may be in the middle of writing to the repository, and killing it can leave the repository in a locked state requiring `restic unlock`. Once the running Job finishes, rerun `make restore`. To bypass the guard (not recommended): `FORCE=1 make restore`.

### Step 3: Scale the StatefulSet to 0

LevelDB holds an exclusive write lock on its data directory. The app pod must be stopped before the restore Job mounts the PVC for writing. The restore Job and the app pod cannot both mount the PVC in `ReadWriteOnce` mode simultaneously.

```bash
kubectl scale statefulset leveldb-app --replicas=0 -n leveldb-system
kubectl rollout status statefulset/leveldb-app -n leveldb-system --timeout=120s
```

### Step 4: Run the restore Job

The restore Job mounts the same PVC read-write at `/restore-target` and runs:

```bash
# Restore snapshot into a work directory
restic restore "${SNAPSHOT_ID}" --target /restore-target/.restore-work

# Verify the expected data path exists
# (restored files land at: .restore-work/backup-source/leveldb/)

# Preserve any existing data directory
mv /restore-target/leveldb /restore-target/leveldb.pre-restore-<timestamp>

# Atomically replace with restored data
mv /restore-target/.restore-work/backup-source/leveldb /restore-target/leveldb

# Clean up work directory
rm -rf /restore-target/.restore-work
```

The existing `leveldb` directory is moved aside (not deleted) before the new data is placed. This preserves the previous state for inspection if the application fails to start after restore.

By default, the latest snapshot is restored. To restore to a specific snapshot:

```bash
SNAPSHOT=abc12345 make restore
```

The restore Job prints the ten most recent snapshots at the start of its run so you can identify the target snapshot ID.

### Step 5: Verify restored data

After Restic completes, the restore Job verifies the expected path exists at `/restore-target/leveldb`. If the path is absent, the Job exits non-zero, the script halts, and recovery instructions are printed.

### Step 6: Scale up and resume

On success:

```bash
kubectl scale statefulset/leveldb-app --replicas=1 -n leveldb-system
kubectl rollout status statefulset/leveldb-app -n leveldb-system --timeout=120s
make resume-backups
```

On failure, the script leaves replicas at 0 and backups suspended, then prints recovery instructions. This is a safety control: it prevents the application from starting against a PVC whose contents are unknown. An operator must inspect the state and either retry the restore or manually confirm the data is usable before scaling up.

---

## Restore operator procedure

```bash
make restore
```

`scripts/restore.sh` performs the full workflow automatically: suspends the CronJob, scales the app to 0, runs the restore Job, scales back up, and resumes the CronJob. If any step fails, the script halts and prints recovery instructions. The app remains stopped and backups remain suspended until an operator resolves the failure.

To restore a specific snapshot:

```bash
SNAPSHOT=abc12345 make restore
```

The restore Job prints the ten most recent snapshots at the start of its run. You can also inspect available snapshots via `make backup-status`.

---

## Restore failure recovery

If `make restore` fails, the script stops and leaves the system in a deliberate holding state:
- StatefulSet replicas: 0 (app is not running)
- CronJob: suspended (no new backups will fire)
- PVC contents: unknown (may be partially restored, may be empty, may be intact)

The app remains stopped and backup scheduling remains suspended until an operator inspects the state and takes an explicit action. This avoids starting the application against a PVC whose contents are unknown—doing so risks operating on incomplete or inconsistent data, depending on how far the restore progressed before the failure.

**Recovery steps:**

1. Inspect the restore Job logs:
   ```bash
   make logs
   # or directly:
   kubectl logs -n leveldb-system -l app.kubernetes.io/component=restore --tail=100
   ```

2. Determine whether the Restic snapshot is intact:
   ```bash
   make backup-status
   ```

3. If the snapshot is intact, retry `make restore`. Each restore run moves the existing `leveldb` directory aside before placing the restored data, so previous attempts are preserved for inspection.

4. If no valid snapshot is available (e.g., the MinIO backend is corrupted or unavailable), assess whether the existing data on the PVC is usable. Mount the PVC in a debug pod and inspect the LevelDB files.

5. After resolution, manually scale up:
   ```bash
   kubectl scale statefulset/leveldb-app --replicas=1 -n leveldb-system
   make resume-backups
   ```

---

## Restic repository management

**Initialize the repository (done once by the deploy script):**

```bash
restic -r s3:http://minio.minio-system.svc.cluster.local:9000/restic init
```

If the repository already exists, `restic init` exits with a non-zero code. The deploy script checks for existence before initializing.

**List snapshots:**

```bash
restic -r s3:http://minio.minio-system.svc.cluster.local:9000/restic snapshots
```

**Verify repository integrity:**

```bash
restic -r s3:http://minio.minio-system.svc.cluster.local:9000/restic check
```

**Unlock a locked repository (only if a backup Job was interrupted):**

```bash
restic -r s3:http://minio.minio-system.svc.cluster.local:9000/restic unlock
```

A Restic lock is a file in the repository. If a backup Job is killed mid-run, the lock file remains. Do not unlock unless you are certain no other Restic process is running.

---

## MinIO configuration

MinIO is deployed via its official Helm chart into the `minio-system` namespace. The backup bucket is created by the deploy script.

**Bucket name:** `restic` (provisioned by `scripts/deploy-minio.sh`)

**Access:** backup and restore Jobs receive MinIO credentials via Kubernetes Secrets mounted as environment variables.

**Durability:** in the local POC, MinIO data lives on a PVC. If the cluster is destroyed, the MinIO data is lost. For production, use erasure-coded MinIO with at least four drives, or replace MinIO with cloud object storage.

---

## Production hardening

Beyond the core workflow, the following should be added for production use:

- **LVM or CSI snapshot consistency** — as described in [Consistency boundary](#consistency-boundary)
- **Remote backup copy** — Restic supports multiple backends. Configure a second Restic repository on external object storage for off-site DR
- **Backup encryption key rotation** — Restic supports adding and removing repository keys without re-encrypting all data
- **NetworkPolicy** — restrict backup Job egress to MinIO only; restrict MinIO ingress to the `leveldb-system` namespace
- **Restore drill** — test the restore procedure on a schedule (monthly or quarterly) against a non-production environment. Untested restore procedures are not restore procedures.
