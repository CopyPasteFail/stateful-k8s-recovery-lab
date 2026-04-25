# AGENTS.md — Coding Agent Instructions

This file provides instructions for any coding agent (AI or automated system) working in this repository. Read this before making any changes.

---

## Repository purpose

This is a production-oriented reference implementation for a stateful Kubernetes application. It is designed to be correct, operable, and instructive—not minimal. Every implementation decision should be accompanied by a short rationale comment or inline note explaining the why, not just the what.

---

## What exists now

- Documentation and planning files only
- No Kubernetes manifests, Helm charts, scripts, or Go source code have been created yet

---

## Implementation order

Follow this sequence. Do not skip phases or implement a later phase before an earlier one is complete and verified.

### Phase 1 — Operator scaffolding

1. `Makefile` — targets listed in the design. Each target calls exactly one script. No complex logic in the Makefile itself.
2. `scripts/*.sh` — one script per Make target. Scripts must be idempotent (safe to run twice without side effects).

### Phase 2 — Go application

3. `app/` — Go HTTP service. See the API spec below. LevelDB backend. Non-root container. Prometheus metrics via the standard `/metrics` endpoint.

### Phase 3 — Kubernetes resources

4. `charts/leveldb-app/` — Helm chart. Covers: StatefulSet, PVC, Service, ServiceAccount, RBAC, ConfigMap, Secret template, backup CronJob, restore Job template.

### Phase 4 — Platform dependencies

5. MinIO: use the official Helm chart. Deploy script applies Helm values via a versioned `values.yaml`.
6. Observability stack: Prometheus, Grafana, Alertmanager, Loki via Helm. Include dashboard provisioning and alert rules as Helm values or ConfigMaps.

### Phase 5 — Documentation sync

7. After each phase, update the relevant `docs/` file to reflect what was actually implemented versus what was planned.

---

## Constraints for every file you create or edit

### Shell scripts

- Target `bash` with `set -euo pipefail` at the top of every script
- Every script must be idempotent: running it twice must not leave the system in a broken state
- Use meaningful exit codes and print clear error messages before exiting non-zero
- Never hardcode credentials or secrets. Read them from environment variables or Kubernetes Secrets
- Do not use `sudo` inside scripts unless the script is explicitly the Docker installation script
- Annotate non-obvious logic with a single-line comment explaining why, not what

### Makefile

- Targets call `scripts/<target>.sh` directly
- No shell logic beyond variable expansion in the Makefile
- `make help` must list all targets with a one-line description
- Use `.PHONY` for all non-file targets

### Go application

- Standard library only unless a dependency is clearly necessary (LevelDB binding, Prometheus client, structured logging)
- Non-root user in the Dockerfile (UID 1000, matching the `app` user created in the Dockerfile)
- `/healthz` returns 200 immediately (liveness — is the process alive?)
- `/readyz` returns 200 only when the LevelDB file is open and writable (readiness — is the app able to serve?)
- `/metrics` uses the standard Prometheus client format
- Storage path is configurable via environment variable, defaulting to `/data/leveldb`
- Graceful shutdown: handle SIGTERM, close LevelDB before exiting

### Helm chart

- All values that vary between environments must be in `values.yaml` with documented defaults
- Do not use deprecated Kubernetes API versions
- Resource requests and limits must be set for all containers (including backup sidecar/job)
- The backup CronJob must have `concurrencyPolicy: Forbid`
- The restore Job must mount the same PVC as the StatefulSet. The StatefulSet must be scaled to 0 before the restore Job runs; enforce this in the restore script, not the Job spec

### Kubernetes security

- All containers run as non-root unless there is a specific documented reason
- Service accounts have only the RBAC permissions they need
- Do not mount `serviceAccountToken` unnecessarily (`automountServiceAccountToken: false` where not needed)
- Secrets are never committed to git. The deploy scripts populate them at runtime from a local `.env` file

---

## API specification

```
PUT  /kv/{key}     — store value (body = raw bytes), return 204
GET  /kv/{key}     — retrieve value, return 200 with body or 404
DELETE /kv/{key}   — delete key, return 204 or 404
GET  /healthz      — liveness probe, return 200 {"status":"ok"}
GET  /readyz       — readiness probe, return 200 or 503
GET  /metrics      — Prometheus text exposition
```

Keys are URL path segments. Treat them as opaque strings. Reject empty keys with 400. Maximum key length: 512 bytes. Maximum value size: configurable, default 10 MiB.

---

## Environment variables used by the application

| Variable | Default | Purpose |
|---|---|---|
| `DATA_DIR` | `/data/leveldb` | LevelDB data directory |
| `PORT` | `8080` | HTTP listen port |

---

## Environment variables used by backup/restore

| Variable | Purpose |
|---|---|
| `RESTIC_REPOSITORY` | Restic repo URL, e.g. `s3:http://minio.minio-system.svc.cluster.local:9000/restic` |
| `RESTIC_PASSWORD` | Restic repository encryption password |
| `AWS_ACCESS_KEY_ID` | MinIO access key |
| `AWS_SECRET_ACCESS_KEY` | MinIO secret key |

---

## Testing requirements

- Go unit tests for the HTTP handler layer (use `httptest.NewRecorder`)
- Integration test that starts the server against a real LevelDB directory in a temp dir
- `make smoke-test` script must verify the full PUT/GET/DELETE cycle against a running cluster

---

## What not to do

- Do not add features not specified in the design documents
- Do not use `helm install --replace` or `--force` flags
- Do not set `replicas > 1` on the app StatefulSet for writes
- Do not pretend HPA with shared LevelDB is safe — if you add HPA, make it read-only replica scoped
- Do not add a `sleep` to a readiness or liveness probe
- Do not commit `.env` files, kubeconfig files, or any file containing credentials
- Do not create `README.md` files inside subdirectories unless asked

---

## Where to look when something is ambiguous

1. `docs/tradeoffs.md` — design decisions and their rationale
2. `docs/architecture.md` — component relationships and data flow
3. `docs/backup-restore.md` — backup and restore design
4. `HUMAN.md` — operator perspective on how things should behave
5. Ask via a comment in the relevant file or PR description if still unclear
