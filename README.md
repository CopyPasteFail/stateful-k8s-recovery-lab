# stateful-k8s-recovery-lab

A production-oriented reference implementation for running a stateful application on Kubernetes with automated backup, point-in-time restore, and full observability.

The application is a Go HTTP key-value service backed by LevelDB. Everything here—backup, restore, monitoring, alerting—is designed to be understandable, operable, and extensible rather than minimal or toy-grade.

---

## What this demonstrates

- Running a stateful workload as a Kubernetes `StatefulSet` with a persistent `PersistentVolumeClaim`
- Automated Restic backups to a local MinIO bucket on a 6-hour `CronJob` schedule
- Safe manual backup and restore with concurrency guards and rollback steps
- Full observability: Prometheus metrics, Grafana dashboards, Alertmanager rules, and Loki log aggregation
- A Makefile-driven operator workflow with idempotent shell scripts backing every target

---

## Prerequisites

- Ubuntu 22.04 / WSL2 Ubuntu 22.04
- Docker Engine (not Docker Desktop)
- k3d, kubectl, Helm

Run `make check-prereqs` to verify your environment. Run `make install-prereqs` to install missing tools, or `make install-docker` for the Docker Engine setup step.

> **Bootstrap note:** `make install-prereqs` installs `make` itself. If `make` is not yet present, either install it first (`sudo apt-get install -y make`) or run the script directly: `bash scripts/install-prereqs.sh`.

---

## Quickstart

```bash
git clone https://github.com/CopyPasteFail/stateful-k8s-recovery-lab.git
cd stateful-k8s-recovery-lab

make demo       # app + MinIO + backup — the core workflow (~3-5 min)
make demo-full  # adds Prometheus, Grafana, Loki (~10-15 min first run)
```

Or run steps individually:

```bash
make check-prereqs        # verify environment
make bootstrap            # create k3d cluster and namespaces
make deploy-minio         # deploy MinIO into minio-system (local S3 backend)
make deploy               # deploy the app StatefulSet (no CRD dependency)
make deploy-observability # deploy Prometheus, Grafana, Loki, Alertmanager
MONITORING=1 make deploy  # re-deploy app with ServiceMonitor + PrometheusRule enabled
make seed-data            # write sample keys to verify the app works
make smoke-test           # run end-to-end sanity checks
```

> **Restore is not part of the demo.** Restore is a disruptive recovery operation — it scales the app to zero and overwrites PVC data. To validate it manually after the demo: `make restore`

### Local app development (no cluster required)

```bash
make test-app             # run Go unit tests
make run-app-local        # start the app on localhost:8080 (data in .local/leveldb)

# Example usage while running:
curl -X PUT  http://localhost:8080/kv/greeting -d "hello"
curl         http://localhost:8080/kv/greeting
curl -X DELETE http://localhost:8080/kv/greeting
curl         http://localhost:8080/healthz
curl         http://localhost:8080/metrics
```

---

## Backup and restore workflow

```bash
make backup              # trigger a one-off Job from the backup CronJob spec
make backup-status       # show CronJob status and recent Job logs
make suspend-backups     # pause the CronJob (maintenance window)
make resume-backups      # re-enable the CronJob

make restore             # guided restore: scale down, restore snapshot, scale up
```

The backup CronJob runs every 6 hours (`0 */6 * * *`, `concurrencyPolicy: Forbid`).
It mounts the app PVC read-only and runs Restic against the LevelDB data directory.
MinIO (in-cluster) is the Restic backend. Local demo credentials are in
`helm-values/minio.yaml` — replace with external secrets for production.

> **Local demo vs production:** The CronJob backs up the live-mounted data directory.
> This is acceptable for exercising the workflow. Production should back up from an
> LVM or CSI volume snapshot for crash-consistency.
> See [docs/backup-restore.md](docs/backup-restore.md) for details.

See [docs/backup-restore.md](docs/backup-restore.md) for the full operator procedure.

---

## Observability

```bash
make port-forward        # open Grafana, Prometheus, and Alertmanager locally
make logs                # tail app and backup Job logs via Loki
make status              # summarize cluster, StatefulSet, PVC, and CronJob state
```

See [docs/observability.md](docs/observability.md) for dashboard and alert details.

---

## Repository layout

```
stateful-k8s-recovery-lab/
├── Makefile
├── README.md
├── HUMAN.md               # operator runbook
├── AGENTS.md              # instructions for coding agents
├── scripts/               # idempotent shell scripts for each Make target
│   ├── demo.sh                      # make demo (core workflow)
│   ├── demo-full.sh                 # make demo-full (+ observability)
│   ├── check-prereqs.sh
│   ├── install-prereqs.sh
│   ├── install-docker.sh
│   ├── bootstrap.sh
│   ├── deploy.sh
│   ├── deploy-minio.sh
│   ├── deploy-observability.sh
│   ├── seed-data.sh
│   ├── backup.sh
│   ├── backup-status.sh
│   ├── suspend-backups.sh
│   ├── resume-backups.sh
│   ├── restore.sh
│   ├── smoke-test.sh
│   ├── logs.sh
│   ├── status.sh
│   ├── port-forward.sh
│   └── destroy.sh
├── charts/                # Helm chart for the Go app and backup resources
│   └── leveldb-app/
├── helm-values/           # Helm values files for third-party charts
│   ├── minio.yaml                   # MinIO standalone (local demo, ClusterIP, 5Gi)
│   ├── kube-prometheus-stack.yaml   # Prometheus + Grafana + Alertmanager
│   ├── loki.yaml                    # Loki SingleBinary (filesystem storage)
│   └── promtail.yaml                # Promtail DaemonSet (log shipper)
├── app/                   # Go HTTP service source
│   └── ...
└── docs/
    ├── architecture.md
    ├── backup-restore.md
    ├── migration.md
    ├── observability.md
    ├── tradeoffs.md
    ├── local-development.md
    └── roadmap.md
```

---

## Scope and limitations

- **Local POC** runs on k3d. It does not require production-scale data volumes—a few megabytes is sufficient to exercise the full workflow.
- **LevelDB is single-writer**. Horizontal scaling with multiple replicas sharing one dataset is not safe. See [docs/tradeoffs.md](docs/tradeoffs.md) for the rationale and recommended scaling models.
- **Production design** extends this foundation with LVM snapshots for backup consistency, external secret management, cloud object storage, and NetworkPolicies.

---

## Documentation

| File | Purpose |
|---|---|
| [HUMAN.md](HUMAN.md) | Detailed human operator guide |
| [AGENTS.md](AGENTS.md) | Instructions for coding agents extending this repo |
| [docs/architecture.md](docs/architecture.md) | System design and Mermaid diagram |
| [docs/backup-restore.md](docs/backup-restore.md) | Backup/restore procedure and design rationale |
| [docs/observability.md](docs/observability.md) | Metrics, dashboards, alerts, and log queries |
| [docs/tradeoffs.md](docs/tradeoffs.md) | Design decisions with rationale |
| [docs/migration.md](docs/migration.md) | Data migration and upgrade procedures |
| [docs/local-development.md](docs/local-development.md) | Developer setup |
| [docs/roadmap.md](docs/roadmap.md) | Phased implementation plan |
