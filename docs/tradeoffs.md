# Design Tradeoffs

This document records the key design decisions made in `stateful-k8s-recovery-lab`, the alternatives considered, and the rationale for each choice. The goal is to make the reasoning explicit so that future operators or contributors can evaluate whether a decision still holds.

---

## LevelDB as the storage engine

**Decision:** Use LevelDB (via a Go binding) as the embedded key-value store.

**Alternatives considered:**
- SQLite — supports concurrent readers but similar single-writer model; less common in Go k8s contexts
- BoltDB/bbolt — pure Go embedded k/v store; simpler but has no compaction and is not actively developed
- External database (Redis, PostgreSQL) — removes the embedded constraint but changes the problem entirely; no longer a useful demo of stateful pod management

**Rationale:** LevelDB is a realistic embedded storage choice that forces explicit decisions about write concurrency, consistency, backup, and scaling. These decisions are the point of this reference. A system backed by a managed database (RDS, CloudSQL) hides the operational complexity that this repo is designed to demonstrate.

---

## StatefulSet, not Deployment {#statefulset}

**Decision:** Deploy the application as a `StatefulSet`.

**Rationale:** `StatefulSet` provides stable pod identities and stable PVC bindings. When `leveldb-app-0` restarts, it reconnects to the same PVC it was using before. A `Deployment` with `replicas: 1` and a manually bound PVC would work in practice but is not the idiomatic pattern for stateful workloads. Using `StatefulSet` also enables the shard-per-pod scaling model where each pod (`leveldb-app-0`, `leveldb-app-1`) owns a disjoint PVC via `volumeClaimTemplates`.

---

## Single writer per LevelDB dataset {#leveldb-scaling}

**Decision:** Lock the write StatefulSet to `replicas: 1`. The Helm chart values schema (`values.schema.json`) enforces this at render time: `helm template` and `helm install` will fail if `replicaCount` is set to any value other than `1`.

**Rationale:** LevelDB uses an exclusive file lock (`LOCK`) on its data directory. A second process attempting to open the same directory for writing will either fail immediately or corrupt data depending on the OS and lock behavior. This is not a configuration limitation—it is a fundamental property of LevelDB's design.

**Safe scaling models:**

| Model | Mechanism | Constraint |
|---|---|---|
| Vertical scaling | Increase pod CPU/memory | Bounded by node size |
| Shard-per-pod | Each `leveldb-app-N` pod owns a disjoint key range; client routes by key | Requires client-side sharding logic |
| Tenant partitioning | Each tenant gets a separate StatefulSet | Operational overhead scales with tenant count |
| Read replicas | Serve reads from a crash-consistent snapshot copy | Requires application-level support for eventual consistency |

**What not to do:** Do not configure HPA targeting `replicas > 1` on the app StatefulSet. Do not use a `ReadWriteMany` PVC and hope that LevelDB will handle concurrent access—it will not.

---

## Restic for backup {#restic}

**Decision:** Use Restic, not `rsync`, `tar`, or a database-native dump.

**Rationale:**
- **Incremental by default:** Restic uses content-defined chunking and deduplication. After the first full backup, subsequent runs transfer only changed chunks. This is critical for 2 TB datasets on a 6-hour interval.
- **Encryption:** The repository is encrypted before any data leaves the pod. MinIO holds only ciphertext.
- **Integrity verification:** Restic supports `restic check` to verify the repository index. The local demo backup Job does not run `restic check` after every snapshot — production deployments should schedule periodic integrity checks and retention pruning (`restic forget --prune`) separately from the six-hour backup path.
- **Point-in-time restores:** Restic keeps multiple snapshots. Operators can restore to any snapshot, not just the latest.

**Alternative considered:** Velero — a Kubernetes-native backup tool. Velero is appropriate for cluster-level backups (namespaces, resources). It is not designed for application-level data backup of a file directory. Restic is the better tool when the unit of backup is a directory.

**Stable host for parent snapshot selection:** Restic uses the `--host` flag to identify which previous snapshot to use as the parent for an incremental backup. Kubernetes Job pod names change on every run. Without an explicit `--host`, each run reports a different host name, so Restic cannot find a parent and falls back to reading every file (`no parent snapshot found, will read all files`). The backup CronJob passes `--host "${RESTIC_HOST}"` (default: `leveldb-app`) so Restic consistently selects the correct parent snapshot, keeping incremental transfers small. This is especially important at the 2 TB design scale.

---

## MinIO as local backup backend {#minio}

**Decision:** Use MinIO as the local S3-compatible object store for backup storage in the local POC.

**Rationale:** External cloud storage (AWS S3, GCS) requires network access and cloud credentials. MinIO runs entirely within the cluster, making the full backup and restore workflow exercisable without external dependencies. The Restic `s3:` backend URL is the same format for MinIO and AWS S3—switching to cloud storage requires only a URL and credential change.

**Production recommendation:** In production, replace or back MinIO with durable object storage. MinIO's durability in this POC is limited to the single in-cluster PVC.

---

## CronJob for scheduled backups {#cronjob}

**Decision:** Use a Kubernetes `CronJob` rather than an in-app scheduler or an external cron.

**Rationale:** The CronJob is managed by Kubernetes, survives pod restarts, and integrates with `kubectl`, Prometheus, and the operator's normal toolchain. The Job runs in an isolated container with the Restic binary and MinIO credentials—it is not a dependency of the app container.

`concurrencyPolicy: Forbid` is set to keep backup execution predictable. Restic uses repository-level locking; a second concurrent Job will contend on that lock and either fail or stall. Beyond the lock, overlapping Jobs create compounding problems: ambiguous backup status, doubled I/O on the PVC, and doubled object-store bandwidth. Skipping a scheduled run when a Job is already in progress is the correct behavior.

---

## One-off Job from CronJob spec (manual backup) {#manual-backup}

**Decision:** `make backup` creates a one-off `Job` using `kubectl create job --from=cronjob/...` rather than a separate Job manifest.

**Rationale:** Deriving the manual Job from the CronJob spec ensures they use the same container image, environment variables, and volume mounts. A separate Job manifest would drift from the CronJob spec over time.

---

## Backup consistency: live directory vs. LVM snapshot {#consistency}

**Decision:** Local POC backs up the live directory. Production uses LVM snapshots.

**Rationale:** LevelDB's WAL means the database can typically recover from a crash-consistent (but not file-system-consistent) backup. However, relying on WAL recovery from a live-read backup is not a safe production strategy for large datasets where a single torn file can prevent recovery.

LVM snapshots are near-instantaneous, do not require stopping the application, and provide a crash-consistent point in time. The backup Job applies the snapshot, mount, backup, unmount, delete snapshot sequence. This is the right model for production.

CSI volume snapshots are the cloud-native equivalent of LVM snapshots and are preferred on managed Kubernetes where the CSI driver supports them.

For a concrete LVM example script and CSI manifests, see [docs/production-snapshots.md](production-snapshots.md).

---

## Secrets management {#secrets}

**Decision:** Kubernetes `Secrets` for local POC. External Secrets Operator for production.

**Rationale:** Kubernetes `Secrets` store base64-encoded values in etcd. They are not encrypted at rest by default (unless the cluster is configured for encryption at rest) and are accessible to anyone with RBAC access to read Secrets in the namespace. For a local development cluster, this is acceptable.

For production:
- Enable etcd encryption at rest for Secrets
- Use the External Secrets Operator to sync secrets from AWS Secrets Manager, GCP Secret Manager, or HashiCorp Vault
- Rotate the Restic repository password and MinIO credentials on a defined schedule
- Never commit `.env` files or Secret manifests with real values to git

---

## Non-root containers {#security}

**Decision:** All containers run as non-root (UID 1000 for both the app and backup containers).

**Rationale:** Running as root in a container provides no application benefit and widens the blast radius of a container escape. The app needs to read and write the PVC; it does not need root privileges. The PVC's `fsGroup` in the pod security context ensures the mount is writable by the non-root user.

---

## NetworkPolicies as production hardening {#networkpolicy}

**Decision:** The chart ships an optional `NetworkPolicy` template, intentionally disabled by default. The local POC does not depend on network isolation — the demo proves the backup/restore and observability flow, not a full production network isolation model.

**Tradeoff:** Disabling NetworkPolicy by default keeps the demo portable and avoids brittle environment-specific selectors breaking Prometheus scraping or local workflows. Enabling it imposes a safer production posture but requires validating every traffic path against the actual CNI, namespace layout, pod labels, and endpoints.

**Rationale:** k3d/k3s can enforce NetworkPolicy depending on the CNI in use (e.g., kube-router behavior in k3s, or Calico/Cilium when installed). Whether enforcement is active depends on the specific cluster configuration. Applying NetworkPolicies without a CNI that enforces them gives a false sense of security; applying them with wrong selectors can silently break scraping or egress. In production (with a CNI that enforces NetworkPolicies), enable the template and adapt it to the actual cluster:
- `leveldb-system` pods: ingress from `observability` namespace (Prometheus scrape) only; egress to MinIO only
- `backup` Jobs: egress to MinIO only
- `minio-system` pods: ingress from `leveldb-system` namespace only
- DNS egress (port 53 UDP/TCP) must be explicitly allowed if the policy uses `policyTypes: Egress`
- Object-store/backup egress CIDRs must match the actual MinIO or cloud storage endpoint

---

## Makefile as the operator interface {#makefile}

**Decision:** Expose all operations through a `Makefile` backed by idempotent shell scripts.

**Rationale:** A Makefile provides a discoverable interface (`make help`), tab completion in most shells, and a single entry point that works consistently across team members' environments. The Makefile itself contains no logic—all logic is in shell scripts. This separation makes the scripts testable independently and keeps the Makefile readable.

**Alternative considered:** A CLI tool written in Go. A Go CLI is more portable and easier to unit test than shell scripts, but it adds a build step and requires a Go toolchain on the operator's machine. Shell scripts have zero build overhead and are appropriate for a reference implementation of this scope.

---

## k3d for local Kubernetes {#k3d}

**Decision:** k3d (k3s in Docker) for the local cluster.

**Alternatives considered:**
- minikube — heavier, uses a VM by default; slower start times
- kind — similar to k3d but slightly less resource efficient; either is acceptable
- Docker Compose — not Kubernetes; eliminates the value of exercising Kubernetes APIs

**Rationale:** k3d creates a lightweight multi-node-simulated cluster in Docker containers. It starts in under 30 seconds, requires no VM, and supports the full Kubernetes API including `StatefulSet`, `CronJob`, `PersistentVolumeClaim`, and `ServiceMonitor`. It is the lowest-friction way to run a realistic Kubernetes environment on a developer laptop.

---

## Helm for packaging {#helm}

**Decision:** Use Helm for the app chart and public Helm charts for platform dependencies (MinIO, Prometheus, Loki).

**Rationale:** Helm is the standard packaging mechanism for Kubernetes applications. Using public charts for dependencies avoids maintaining custom manifests for well-supported components. The app chart (`charts/leveldb-app/`) is a first-party chart that owns the StatefulSet, CronJob, RBAC, and alert rules specific to this application.

**Alternative considered:** Kustomize. Kustomize is appropriate for managing environment-specific overlays on top of base manifests. It does not have a packaging or dependency mechanism. Using Helm for the app and Kustomize for overlays is a valid production pattern, but for a reference implementation that targets a single environment (local k3d), Helm alone is sufficient.
