# HUMAN.md - Operator Demo Guide

This guide is for a human operator who wants to bring the system up, prove that it works, inspect the moving parts, and cleanly remove the local cluster afterward.

For deeper detail, see:
- [docs/architecture.md](docs/architecture.md)
- [docs/backup-restore.md](docs/backup-restore.md)
- [docs/observability.md](docs/observability.md)
- [docs/tradeoffs.md](docs/tradeoffs.md)

---

## Quick Setup and Teardown Flow

### Prerequisites Verification and Installation
**Required platform:** Linux. The scripts are written for bash on Linux. They are not tested on macOS or native Windows.
> The repo was tested on WSL2 Ubuntu 22.04

```bash
# Clone the repository and enter it.
git clone https://github.com/CopyPasteFail/stateful-k8s-recovery-lab.git
cd stateful-k8s-recovery-lab

# Check prerequisites first. Install only what is missing.
if ! make check-prereqs; then
  make install-prereqs
  make check-prereqs
fi
```

If Docker itself is missing, install it separately and rerun the check.
```bash
make install-docker
```

### Run the Full Demo Flow

```bash
# Run the full demo. This includes the observability stack.
make demo-full

# Show the cluster and workload state after the demo finishes.
make status

# Prove the app endpoints and key-value round trip still work.
make smoke-test

# Show backup state and the latest Restic snapshot output.
make backup-status
```

### (Optional) Inspect the UI

```bash
make port-forward-all
make port-forward-stop
```

### Verify Backup and Restore End to End

`make restore-drill` runs a self-contained backup-and-restore cycle. It writes known keys to the app, takes a backup, overwrites those keys with different values, runs a full restore, and verifies that the original values are recovered. The command prints `PASSED` or `FAILED` at the end.

This is opt-in and separate from the main demo. It scales the app down and up as part of the restore step, so run it when no other operations are in progress.

```bash
make restore-drill
```

### Clean Up

```bash
make destroy FORCE=1
```

## What Full Demo Does
- boots the local k3d cluster named `stateful-recovery`
- creates the `leveldb-system`, `minio-system`, and `observability` namespaces
- deploys MinIO
- deploys the app
- deploys Prometheus, Grafana, Alertmanager, Loki, and Alloy
- seeds sample data
- runs a backup
- runs the smoke test
- prints backup status and cluster status

---

## What To Verify After The Run

After `make demo-full`, `make status` should show:
- k3d cluster `stateful-recovery`
- namespace `leveldb-system`
- pod `leveldb-app-0` in `Running` and `Ready`
- MinIO pod in `Running`
- observability pods in `Running`
- backup CronJob present
- `ServiceMonitor` present
- `PrometheusRule` present

`make smoke-test` should prove:
- `GET /healthz` returns 200
- `GET /readyz` returns 200
- `GET /metrics` is reachable
- `PUT /kv/{key}`, `GET /kv/{key}`, and `DELETE /kv/{key}` work as a round trip

`make backup-status` should show:
- the backup CronJob
- a recent backup Job
- Restic snapshot output

Grafana should show:
- app request rate and latency
- readiness
- LevelDB errors
- backup-related panels if they are present in the dashboard

Prometheus should have the app metrics:
- `http_requests_total`
- `http_request_duration_seconds`
- `leveldb_errors_total`
- `app_ready`

MinIO Console should show the `restic` bucket.

---

## Useful Local Access Points

Start all local access points in one terminal with `make port-forward-all`. Stop them later with `make port-forward-stop`.
The port-forward commands print local-demo credentials for UIs that require login, such as Grafana and MinIO Console.

| Component | Command | Local URL |
|---|---|---|
| All available local access points | `make port-forward-all` | `http://localhost:3000`, `:9090`, `:9093`, `:9001`, `:18081` |
| Stop tracked port-forwards | `make port-forward-stop` | n/a |
| Grafana | `make port-forward TARGET=grafana` | `http://localhost:3000` |
| Prometheus | `make port-forward TARGET=prometheus` | `http://localhost:9090` |
| Alertmanager | `make port-forward TARGET=alertmanager` | `http://localhost:9093` |
| MinIO Console | `make port-forward TARGET=minio-console` | `http://localhost:9001` |
| App API | `make port-forward TARGET=app` | `http://localhost:18081` |

What to look for:
- Grafana should show the app overview dashboard with request rate, latency, readiness, and backup signals.
- Prometheus should be scraping the app service and exposing the metrics listed above.
- Alertmanager should show the local alerting surface, even though this demo does not forward alerts externally.
- MinIO Console should show the backup bucket and recent activity.
- The app API root should return JSON that lists `GET /healthz`, `GET /readyz`, `GET /metrics`, `PUT /kv/{key}`, `GET /kv/{key}`, and `DELETE /kv/{key}`.
- The app API should respond to the health, readiness, metrics, and key-value endpoints.

---

## What Each Part Does

### Cluster Lifecycle

The cluster is the local Kubernetes runtime for the whole demo. The main flow already created it with `make demo-full`, which also set up the namespaces used by the app, MinIO, and observability.

When it is healthy, `make status` shows the `stateful-recovery` cluster, the expected namespaces, and the running pods that belong to them.

This cluster is disposable. It is meant for repeated local runs, not for long-lived state.

Read more in [docs/architecture.md](docs/architecture.md) and [docs/tradeoffs.md](docs/tradeoffs.md).

### MinIO Deployment

MinIO is the in-cluster object store used by Restic for backup storage in the local demo.

The main flow already deployed it. When it is healthy, the MinIO pod is running and the Console shows the `restic` bucket.

Read more in [docs/backup-restore.md](docs/backup-restore.md) and [docs/tradeoffs.md](docs/tradeoffs.md).

### Application Operations

The app is a single-writer API-only LevelDB service exposed through a Kubernetes `StatefulSet`.

The main demo flow deploys it and seeds sample data.
When it is healthy, `leveldb-app-0` is running and ready, the health and readiness probes pass, and the metrics endpoint exposes the application counters and histograms.
`http://localhost:18081/` returns a small JSON document that lists the useful API endpoints.

The key caveat is that LevelDB supports one writer per dataset. Do not scale the write path horizontally and expect it to behave like a shared database.

Read more in [docs/architecture.md](docs/architecture.md) and [docs/tradeoffs.md](docs/tradeoffs.md).

### Backup Operations

Backups are managed by a Kubernetes `CronJob` that runs Restic against the app PVC.

The main demo flow triggers a backup and prints the current status.
A healthy setup has the CronJob present, a recent Job in the namespace, and snapshots in the Restic repository.

The local demo backs up the live PVC. That is acceptable for a controlled demo, but it is not the production consistency boundary.

Read more in [docs/backup-restore.md](docs/backup-restore.md).

### Observability

The observability stack is Prometheus, Grafana, Alertmanager, Loki, and Alloy.

When it is healthy, Prometheus scrapes the app, Grafana has the app overview dashboard, and Loki receives pod logs.

Read more in [docs/observability.md](docs/observability.md).

### Restore Procedure

Restore is intentionally not part of the main demo. It is disruptive because it suspends scheduled backups, scales the app down to zero, and rewrites the PVC contents before the app starts again.

> It's also possible to restore a specific snapshot instead of the latest one, by running `SNAPSHOT=<id> make restore`

A successful restore brings the app back up and resumes backups.

A failed restore leaves the app stopped and backups suspended until an operator inspects the state and decides the next step.

Read the full procedure in [docs/backup-restore.md](docs/backup-restore.md).

### Maintenance Windows

Scheduled backups can be suspended during maintenance that would interfere with the data path, such as restore work or storage changes.

The main demo does not need this because it follows the normal happy path. Use suspension only when the work itself makes scheduled backups unsafe or misleading.

The important operational rule is to resume backups after the maintenance window closes.

Read more in [docs/backup-restore.md](docs/backup-restore.md).

### Incident Response

Start with `make status`. If you need logs, use `make logs`. If the problem is backup-related, use `make backup-status`.

Common situations:
- If the app is not ready, check whether the pod is running, whether LevelDB opened cleanly, and whether the PVC is attached and writable.
- If a backup failed, inspect the most recent Job and its logs before retrying anything.
- If a restore failed, leave the app stopped until you understand whether the PVC contents are safe to use.
- If MinIO is unavailable, backups cannot complete because Restic has no object store target.
- If observability pods are not ready, the app may still be working, but you will lose the monitoring and dashboard view until those pods recover.

The main idea is to identify whether the problem is with the app, the backup path, the restore path, the object store, or the observability stack, then inspect only the relevant layer.

Read more in [docs/backup-restore.md](docs/backup-restore.md) and [docs/observability.md](docs/observability.md).

### Secrets Management

The local demo uses intentionally simple credentials. They are good enough for a disposable local cluster and should not be treated as production secrets.

In this repo, the local demo credentials cover MinIO and the Restic repository secret. They are populated at runtime and not meant to be reused elsewhere.

The production path is different: use External Secrets or a similar secret manager integration, cloud-managed object storage, and cloud IAM instead of static local credentials.

Read more in [docs/tradeoffs.md](docs/tradeoffs.md).

### Known Limitations

- The local proof-of-concept backs up a live PVC. In production, use LVM or CSI snapshots as the consistency boundary.
- The in-cluster MinIO deployment is local-demo storage, not durable production object storage.
- The system is designed with a 2 TB production scale in mind, but it does not allocate that size locally.
- The recovery point objective is six hours. The recovery time objective depends on restore throughput and the size of the dataset.
- LevelDB is a single-writer store. Do not treat it like a horizontally writable replicated database.
- Terraform is not part of the local demo flow.
- NetworkPolicy is present as a production-readiness example, not as a dependency of the local demo. k3d/k3s may enforce NetworkPolicy depending on networking configuration, but the POC avoids relying on environment-specific policy behavior.

Read more in [docs/backup-restore.md](docs/backup-restore.md) and [docs/tradeoffs.md](docs/tradeoffs.md).

---

## System coverage map

| Operational concern | Where to look | Notes |
|---|---|---|
| Stateful workload deployment | `charts/leveldb-app/` | Helm chart defining the StatefulSet, PVC, and service |
| Persistent storage | `charts/leveldb-app/`, [docs/architecture.md](docs/architecture.md) | PVC provisioning, storage class, and volume mount config |
| Backup schedule and RPO | [docs/backup-restore.md](docs/backup-restore.md) | CronJob schedule; RPO target is six hours |
| Restore procedure | [docs/backup-restore.md](docs/backup-restore.md) | Full restore walkthrough including failure-handling steps |
| Backup consistency boundary | [docs/backup-restore.md](docs/backup-restore.md), [docs/tradeoffs.md](docs/tradeoffs.md), [docs/production-snapshots.md](docs/production-snapshots.md) | Live-PVC backup in local demo; production path requires CSI or LVM snapshots — see production-snapshots.md for concrete examples |
| Scaling model | [docs/tradeoffs.md](docs/tradeoffs.md) | Single-writer LevelDB constraint; horizontal write scaling is not supported |
| Migration and upgrades | [docs/migration.md](docs/migration.md) | Schema and version migration steps |
| Monitoring and dashboards | [docs/observability.md](docs/observability.md) | Prometheus scrape config and Grafana dashboard definitions |
| Alerting | [docs/observability.md](docs/observability.md) | PrometheusRule definitions and Alertmanager configuration |
| Logs and troubleshooting | [docs/observability.md](docs/observability.md), `scripts/logs.sh` | Loki/Alloy pipeline; `make logs` for quick pod log access |
| Security hardening | [docs/tradeoffs.md](docs/tradeoffs.md) | Local demo credential model and production secret management notes |
| Local demo lifecycle | `Makefile`, `scripts/` | `make demo-full` to bring up, `make destroy` to tear down |

---

## Deeper Docs

- [docs/architecture.md](docs/architecture.md) for the component layout and data flow
- [docs/backup-restore.md](docs/backup-restore.md) for backup, restore, and failure handling
- [docs/observability.md](docs/observability.md) for dashboards, alerts, and logs
- [docs/tradeoffs.md](docs/tradeoffs.md) for the design decisions behind the implementation
