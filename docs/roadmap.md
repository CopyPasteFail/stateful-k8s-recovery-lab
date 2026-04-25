# Roadmap

This document describes the planned implementation phases for `stateful-k8s-recovery-lab`. It distinguishes what is in scope for each phase, what prerequisites each phase has, and what a completed phase looks like.

---

## Phase 1 — Local Kubernetes reference implementation

**Goal:** A fully functional, locally runnable system that demonstrates the complete stateful-app lifecycle: deploy, write data, backup, destroy, restore, verify.

**Scope:**

- [ ] `Makefile` with all planned targets (`make help`, `make check-prereqs`, `make bootstrap`, etc.)
- [ ] Shell scripts in `scripts/` backing each target; all scripts idempotent
- [ ] `scripts/check-prereqs.sh` — verify Docker, k3d, kubectl, helm
- [ ] `scripts/install-prereqs.sh` — install k3d, kubectl, helm
- [ ] `scripts/install-docker.sh` — install Docker Engine on Ubuntu
- [ ] `scripts/bootstrap.sh` — create k3d cluster, namespaces, CRDs
- [ ] `scripts/destroy.sh` — tear down the cluster
- [ ] Go HTTP application in `app/`:
  - PUT/GET/DELETE /kv/{key}
  - /healthz, /readyz, /metrics
  - LevelDB backend at /data/leveldb
  - Non-root container, graceful SIGTERM shutdown
- [ ] `Dockerfile` for the application (multi-stage, distroless or scratch final image)
- [ ] `charts/leveldb-app/` Helm chart:
  - StatefulSet with `replicas: 1`
  - PVC via `volumeClaimTemplates`
  - Service, ServiceAccount, RBAC
  - Backup CronJob (`schedule: "0 */6 * * *"`, `concurrencyPolicy: Forbid`)
  - PrometheusRule for backup and app alerts
  - Grafana dashboard ConfigMaps
- [ ] MinIO deployment via official Helm chart
- [ ] `scripts/deploy-minio.sh` — install MinIO, create backup bucket, initialize Restic repository
- [ ] Observability stack via `kube-prometheus-stack` and `loki-stack` Helm charts
- [ ] `scripts/deploy-observability.sh` — install stack, provision dashboards and alerts
- [ ] `scripts/backup.sh` — trigger manual backup Job, check for concurrent Job
- [ ] `scripts/restore.sh` — full restore workflow with concurrency guard, scale-down, verify, scale-up
- [ ] `scripts/smoke-test.sh` — PUT/GET/DELETE cycle + healthz/readyz/metrics checks
- [ ] `scripts/seed-data.sh` — write known keys for test baseline
- [ ] `scripts/status.sh`, `scripts/logs.sh`, `scripts/port-forward.sh`
- [ ] Go unit and integration tests

**Definition of done for Phase 1:**

A person with Ubuntu 22.04 and Docker Engine can clone the repo and run:

```bash
make check-prereqs
make bootstrap
make deploy
make deploy-minio
make deploy-observability
make seed-data
make smoke-test
make backup
make backup-status
make destroy
make bootstrap
make deploy
make deploy-minio
make restore
make smoke-test
```

All targets succeed. The smoke test confirms that data written before `make destroy` is present after `make restore`. Grafana dashboards are reachable. The `BackupJobFailed` and `BackupNotRunRecently` alerts exist and can be triggered manually.

---

## Phase 2 — Production readiness path

**Goal:** Extend the design to be deployable on a real Kubernetes cluster with production-grade consistency, security, and operational hygiene.

**Scope:**

- [ ] LVM or CSI snapshot-based backup consistency (documented with working Job spec)
- [ ] NetworkPolicies for inter-namespace traffic restriction
- [ ] External Secrets Operator integration (optional module; works alongside base Kubernetes Secrets)
- [ ] Alertmanager routing configuration for PagerDuty or Slack
- [ ] Helm values files for multiple environments (`values-dev.yaml`, `values-prod.yaml`)
- [ ] Resource requests and limits tuned for realistic workloads (not just defaults)
- [ ] PodDisruptionBudget to control voluntary disruptions
- [ ] HorizontalPodAutoscaler — disabled for the write path; optional for read-only shard replicas
- [ ] Readiness gate: the app pod is not marked Ready until `/readyz` confirms LevelDB is open
- [ ] Restic retention policy review and documentation
- [ ] Restore drill procedure and verification checklist
- [ ] CI pipeline (GitHub Actions): lint, unit test, Helm lint, chart smoke test against kind cluster

**Definition of done for Phase 2:**

The system can be deployed on a managed Kubernetes cluster (EKS, GKE, or AKS) with external S3-compatible storage, secret rotation, and operational alerting routed to a real receiver. A restore drill on a staging environment completes successfully.

---

## Phase 3 — Advanced extensions

**Goal:** Explore extensions that address real production-scale concerns.

**Scope (any subset; not all are committed):**

- [ ] Terraform module for cloud infrastructure provisioning:
  - S3 bucket with versioning and lifecycle rules
  - IAM role with least-privilege permissions for backup/restore Jobs (IRSA on EKS, Workload Identity on GKE)
  - KMS key for optional server-side encryption of the S3 bucket
  - Managed Kubernetes cluster configuration
  - This module is independent of the local k3d path; it provisions the cloud resources that production uses

- [ ] Shard-per-pod scaling demo:
  - Multiple `leveldb-app` pods, each with a disjoint key range
  - A simple client-side routing layer that hashes the key to the correct pod
  - Backup CronJob per pod (one CronJob per shard)

- [ ] Read-replica demo:
  - A separate pod that mounts a crash-consistent snapshot of the PVC (via CSI clone or LVM snapshot)
  - The replica serves read-only GET requests
  - Data is eventually consistent with the write pod

- [ ] Chaos engineering scenarios:
  - PVC full simulation
  - Network partition between app and MinIO
  - Backup Job kill mid-run (Restic lock behavior)
  - Pod crash during restore

- [ ] `make demo` target:
  - Scripted walkthrough of the full lifecycle
  - Intended for conference demos or team onboarding

- [ ] Helm chart publishing to a public chart repository

---

## What is explicitly out of scope

- Multi-cluster replication
- LevelDB replacement with a distributed database (this is a design decision that removes the core learning, not an extension)
- Production-grade multi-tenant SaaS deployment
- GUI or web frontend for the key-value data
