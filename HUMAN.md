# HUMAN.md — Operator Guide

This document is the authoritative reference for a human operator managing this system. It covers day-to-day operations, incident response, recovery procedures, and maintenance tasks.

For architecture and design decisions see [docs/architecture.md](docs/architecture.md).
For backup and restore procedures see [docs/backup-restore.md](docs/backup-restore.md).

---

## Table of contents

1. [Quick demo](#quick-demo)
2. [Environment setup](#environment-setup)
3. [Cluster lifecycle](#cluster-lifecycle)
4. [MinIO deployment](#minio-deployment)
5. [Application operations](#application-operations)
6. [Backup operations](#backup-operations)
7. [Restore procedure](#restore-procedure)
8. [Observability](#observability)
9. [Maintenance windows](#maintenance-windows)
10. [Incident response](#incident-response)
11. [Secrets management](#secrets-management)
12. [Known limitations](#known-limitations)

---

## Environment setup

**Required platform:** Linux. The scripts are written for bash on Linux. They are not tested on macOS or native Windows.
> The repo wast tested on WSL2 Ubuntu 22.04

**Check your environment:**

```bash
make check-prereqs
```

This runs `scripts/check-prereqs.sh`, which verifies:
- Docker Engine is installed and the daemon is running
- `docker` is executable by the current user without `sudo`
- `k3d` is installed
- `kubectl` is installed and on PATH
- `helm` is installed

**Install missing tools:**

```bash
make install-prereqs      # installs kubectl, helm, k3d, restic, shellcheck, and other tools
make install-docker       # installs Docker Engine (requires sudo)
```

`install-prereqs.sh` also installs `make` itself via apt. If `make` is not yet present on a fresh system, bootstrap it first:

```bash
sudo apt-get update && sudo apt-get install -y make
make install-prereqs
```

Or skip `make` entirely and run the script directly:

```bash
bash scripts/install-prereqs.sh
```

`install-docker.sh` follows the official Docker Engine install path for Ubuntu. After it runs you must log out and back in (or `newgrp docker`) for group membership to take effect.

---

## Quick demo

The fastest way to bring up the full environment and verify everything works:

```bash
make demo        # core workflow: app + MinIO + backup (~3-5 min)
make demo-full   # full platform: adds Prometheus, Grafana, Loki (~10-15 min first run)
```

Both commands are idempotent — safe to run on an already-running cluster.

**Why restore is not part of the demo:** Restore is a disruptive recovery operation. It scales the application to zero replicas and overwrites PVC data. It is not safe to run automatically as part of a demo sequence. To validate the restore path explicitly after the demo:

```bash
make backup            # ensure a recent snapshot exists
make restore           # guided restore: suspend CronJob → scale down → restore → verify → scale up
# or for a specific snapshot:
SNAPSHOT=abc12345 make restore
```

---

## Local app development

Run and test the Go application without a Kubernetes cluster:

```bash
make test-app        # run Go unit tests (app/internal/store and app/internal/httpapi)
make run-app-local   # start the app on http://localhost:8080, data in .local/leveldb
```

While running locally:

```bash
curl -X PUT  http://localhost:8080/kv/mykey -d "myvalue"
curl         http://localhost:8080/kv/mykey
curl -X DELETE http://localhost:8080/kv/mykey
curl         http://localhost:8080/healthz
curl         http://localhost:8080/readyz
curl         http://localhost:8080/metrics
```

Override defaults with environment variables:

```bash
DATA_DIR=/tmp/mydb PORT=9090 make run-app-local
```

The `.local/` directory (default data location) is gitignored.

---

## Cluster lifecycle

**Create the cluster:**

```bash
make bootstrap
```

This runs `scripts/bootstrap.sh`, which:
1. Creates a k3d cluster named `stateful-recovery` with one server node
2. Creates the `leveldb-system`, `minio-system`, and `observability` namespaces
3. Waits for all nodes to reach Ready state

The cluster persists until you explicitly destroy it.

**Destroy the cluster and all data:**

```bash
make destroy
```

This runs `scripts/destroy.sh`. All cluster resources including PVCs are deleted. MinIO data inside the cluster is also deleted. This is irreversible for any data not already backed up externally.

---

## MinIO deployment

MinIO is the S3-compatible object store used as the Restic backup backend. It runs inside the cluster in the `minio-system` namespace and is not exposed externally.

**Deploy MinIO:**

```bash
make deploy-minio
```

This runs `scripts/deploy-minio.sh`, which:
1. Adds/updates the public MinIO Helm repo (`https://charts.min.io/`)
2. Installs or upgrades the `minio` Helm release into `minio-system`
3. Waits for the StatefulSet rollout to complete
4. Verifies the `restic` bucket exists (provisioned by a chart hook Job)

Safe to rerun: `helm upgrade --install` is idempotent. The bucket provisioning Job uses `mc mb --ignore-existing`.

The MinIO client image used for bucket verification is pinned by default and can be overridden:

```bash
MINIO_MC_IMAGE=minio/mc:RELEASE.2025-08-13T08-35-41Z make deploy-minio
```

**Access the MinIO UI or API locally:**

```bash
make port-forward TARGET=minio-api      # MinIO S3 API  -> http://localhost:9000
make port-forward TARGET=minio-console  # MinIO Console -> http://localhost:9001
```

**Local demo credentials** (defined in `helm-values/minio.yaml`):

```
User:     minioadmin
Password: minioadmin
```

These are local-demo-only credentials. Do not reuse them outside this cluster. See [Secrets management](#secrets-management) for the production path.

---

## Application operations

**Deploy the application:**

```bash
make deploy                  # core app only — works on a fresh cluster
MONITORING=1 make deploy     # also creates ServiceMonitor, PrometheusRule, and Grafana dashboard
                             # requires: make deploy-observability first
```

Deploys the `leveldb-app` Helm chart to the `leveldb-system` namespace. This creates:
- A `StatefulSet` with one replica
- A `PersistentVolumeClaim` of configurable size (default: 1Gi for local POC)
- A `Service` for in-cluster access
- A `ServiceAccount` with least-privilege RBAC
- A backup `CronJob` and associated `Secret`
- When `MONITORING=1`: a `ServiceMonitor`, `PrometheusRule`, and dashboard `ConfigMap`

Monitoring resources are disabled by default so `make deploy` works on any cluster, including a fresh one without `kube-prometheus-stack` installed. The `monitoring.coreos.com` CRDs (ServiceMonitor, PrometheusRule) are only required when `MONITORING=1` is set.

**Check status:**

```bash
make status
```

Prints:
- k3d cluster state
- StatefulSet rollout status
- PVC status and bound volume
- Current backup CronJob status and last Job result
- Recent Events in the `leveldb-system` namespace

**Write sample data:**

```bash
make seed-data
```

Writes a set of known key-value pairs. Used to establish a baseline before testing backup and restore.

**Run smoke tests:**

```bash
make smoke-test
```

Verifies:
- The app pod is Running and Ready
- `GET /healthz` returns 200
- `GET /readyz` returns 200
- A PUT/GET/DELETE round trip succeeds
- Metrics are reachable at `GET /metrics`

**Access the application locally:**

```bash
make port-forward TARGET=app            # App API      -> http://localhost:8080
make port-forward TARGET=minio-api      # MinIO S3 API -> http://localhost:9000
make port-forward TARGET=minio-console  # MinIO UI     -> http://localhost:9001
make port-forward                       # print all available targets
```

---

## Backup operations

**Trigger a manual backup:**

```bash
make backup
```

Creates a one-off Kubernetes `Job` from the CronJob spec (`leveldb-app-backup`). The Job mounts the app PVC read-only at `/backup-source`, initializes the Restic repository if it does not exist, runs `restic backup /backup-source/leveldb`, and prints the five most recent snapshots on completion.

**Local demo note:** the CronJob backs up the live data directory. For production, back up from an LVM or CSI snapshot. See [docs/backup-restore.md](docs/backup-restore.md#consistency-boundary).

**Credentials:** Restic password and MinIO credentials are stored in the Kubernetes Secret `leveldb-app-restic` (created by the Helm chart from `helm-values/minio.yaml` values). These are local-demo-only. Do not reuse them in production.

Concurrency: if a backup `Job` is already running, `make backup` exits with a warning rather than create a second Job. Override with `FORCE=1 make backup`. This matches the CronJob's `concurrencyPolicy: Forbid`.

**Check backup status:**

```bash
make backup-status
```

Prints the status and logs of the most recent backup `Job`.

**Suspend scheduled backups:**

```bash
make suspend-backups
```

Sets `spec.suspend: true` on the `CronJob`. Use this before maintenance windows or before starting a restore. The CronJob will not fire new Jobs while suspended, but any running Job completes.

**Resume scheduled backups:**

```bash
make resume-backups
```

Sets `spec.suspend: false`. Always run this after maintenance is complete. A Grafana alert fires if the CronJob remains suspended beyond its expected schedule window.

---

## Restore procedure

The restore workflow is documented in full in [docs/backup-restore.md](docs/backup-restore.md). The short form:

```bash
make restore
```

`scripts/restore.sh` performs the following steps in order:
1. Suspend the backup CronJob
2. Block until any in-progress backup Job completes or fails
3. Scale the `leveldb-app` StatefulSet to 0 replicas
4. Run a one-off restore Job that mounts the PVC and applies the selected Restic snapshot
5. Run verification checks against the restored data
6. On success: scale the StatefulSet back to 1, resume the CronJob
7. On failure: leave backups suspended, leave replicas at 0, print recovery instructions

**Selecting a snapshot:**

By default `make restore` restores the latest Restic snapshot. To restore to a specific snapshot:

```bash
SNAPSHOT=abc12345 make restore
```

**What to do if restore fails:**

Do not scale the StatefulSet back up manually until you understand the cause. The data on the PVC may be in an inconsistent state. See [docs/backup-restore.md](docs/backup-restore.md#restore-failure-recovery).

---

## Observability

**Deploy the observability stack:**

```bash
make deploy-observability   # Prometheus, Grafana, Alertmanager, Loki, Promtail
```

**Open dashboards (one target at a time — each runs in the foreground):**

```bash
make port-forward TARGET=grafana        # http://localhost:3000  (admin / admin)
make port-forward TARGET=prometheus     # http://localhost:9090
make port-forward TARGET=alertmanager   # http://localhost:9093
make port-forward                       # print all available targets
```

**Tail logs:**

```bash
make logs
```

Streams structured logs from the app pod and recent backup/restore Job pods.

**Key dashboards** (see [docs/observability.md](docs/observability.md) for full details):
- `LevelDB App Overview` — HTTP request rate, latency (p50/p95/p99), error rate, app readiness, LevelDB errors, backup job status

**Key alerts:**
- `LevelDBAppDown` — Prometheus cannot scrape the app endpoint for 2 minutes (critical)
- `LevelDBAppNotReady` — `/readyz` failing for 2 minutes; LevelDB may have failed to open (warning)
- `LevelDBHighErrorRate` — continuous LevelDB operation errors for 5 minutes (warning)
- `LevelDBBackupJobFailed` — a backup Job recorded a failure in its Kubernetes status (critical)
- `LevelDBBackupNotRunRecently` — no successful backup in the last 8 hours (warning)

---

## Maintenance windows

**Recommended procedure for maintenance that requires app downtime:**

1. `make suspend-backups` — prevent backup Jobs from firing during maintenance
2. Perform maintenance (upgrade, migration, etc.)
3. `make smoke-test` — verify the app is functional
4. `make backup` — take an immediate post-maintenance backup
5. `make resume-backups`

---

## Incident response

**App pod is CrashLoopBackOff:**

```bash
make status              # check Events and pod state
make logs                # check recent logs
kubectl -n leveldb-system describe pod leveldb-app-0
```

Common causes: PVC not bound, LevelDB lock file left from previous crash, OOM kill.

**No backup for > 6 hours:**

Check `make backup-status`. If the last Job failed, inspect its logs. If the CronJob is suspended, run `make resume-backups` if maintenance is complete.

**PVC full:**

The app and any running backup Job will start failing. Do not delete data blindly. Expand the PVC if the storage class supports it, or follow the migration procedure in [docs/migration.md](docs/migration.md).

**Need to recover from a failed restore:**

See [docs/backup-restore.md](docs/backup-restore.md#restore-failure-recovery).

---

## Secrets management

**Local POC:** credentials (MinIO access key, Restic repository password, Grafana admin password) are stored in Kubernetes `Secrets`. These are populated by the deploy scripts using values in a local `.env` file that is gitignored.

**Production:** do not use Kubernetes `Secrets` with plaintext values in production. The recommended path is an external secrets operator (e.g., External Secrets Operator) backed by a cloud KMS or secrets manager (AWS Secrets Manager, GCP Secret Manager, HashiCorp Vault). See [docs/tradeoffs.md](docs/tradeoffs.md#secrets) for rationale.

---

## Known limitations

- **LevelDB is single-writer.** Running more than one writer against the same LevelDB directory is unsupported. A second writer will normally fail to acquire the database lock, and bypassing that protection can risk data corruption. The StatefulSet is configured with `replicas: 1`. Do not increase this for writes. See [docs/tradeoffs.md](docs/tradeoffs.md#leveldb-scaling) for safe scaling models.
- **Local POC backup consistency.** The CronJob backs up the live-mounted `/data/leveldb` directory. In the local demo this is acceptable. In production, use LVM snapshots to establish a crash-consistent point before Restic reads the data. See [docs/backup-restore.md](docs/backup-restore.md#consistency).
- **k3d is for local use only.** k3d runs Kubernetes in Docker. It is not a production cluster. Use it to exercise the workflow and learn the operational model.
