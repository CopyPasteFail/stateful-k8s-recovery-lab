# Local Development Guide

This document covers how to set up a local development environment and make changes to the Go application or Helm chart.

---

## Platform requirements

- Ubuntu 22.04 or WSL2 Ubuntu 22.04
- Docker Engine (not Docker Desktop)
- Go 1.22+
- k3d
- kubectl
- Helm

```bash
make check-prereqs    # verify all tools are installed
make install-prereqs  # install missing tools (except Docker)
make install-docker   # install Docker Engine
```

---

## Environment verification

After installing prerequisites, verify the full stack from scratch:

```bash
make bootstrap
make deploy
make deploy-minio
make deploy-observability
make seed-data
make smoke-test
```

If all targets succeed, your environment is ready.

---

## Working on the Go application

The application source lives in `app/`. It is a standard Go module.

**Run locally without Kubernetes:**

```bash
make run-app-local
# or: (cd app && go run ./cmd/leveldb-app)
```

The server listens on `:8080` by default. Test with curl:

```bash
curl -X PUT -d "hello world" http://localhost:8080/kv/mykey
curl http://localhost:8080/kv/mykey
curl -X DELETE http://localhost:8080/kv/mykey
curl http://localhost:8080/healthz
curl http://localhost:8080/metrics
```

**Run tests:**

```bash
make test-app
# or: (cd app && go test ./...)
```

Tests use a temporary directory for LevelDB. They do not require a running cluster.

**Build the container image:**

```bash
docker build -t leveldb-app:dev ./app
```

**Load the image into the k3d cluster:**

```bash
k3d image import leveldb-app:dev -c stateful-recovery
```

**Redeploy with the new image:**

```bash
helm upgrade leveldb-app charts/leveldb-app -n leveldb-system \
  --set image.tag=dev \
  --set image.pullPolicy=Never
```

---

## Working on the Helm chart

The Helm chart is at `charts/leveldb-app/`. To validate changes before applying:

```bash
helm lint charts/leveldb-app/
helm template leveldb-app charts/leveldb-app/ --debug
```

To apply changes to the running cluster:

```bash
helm upgrade leveldb-app charts/leveldb-app/ -n leveldb-system
```

To diff the current release against your local changes (requires the `helm-diff` plugin):

```bash
helm diff upgrade leveldb-app charts/leveldb-app/ -n leveldb-system
```

---

## Working on scripts

Each script in `scripts/` corresponds to a Make target. Scripts should be idempotent—running them twice should not produce a different result than running them once.

Test idempotency manually:

```bash
bash scripts/bootstrap.sh
bash scripts/bootstrap.sh   # should not error or recreate existing resources
```

All scripts use `set -euo pipefail`. A single failed command exits the script immediately with a non-zero code. The Make target propagates this exit code.

---

## Viewing logs during development

```bash
# App pod logs
kubectl logs -n leveldb-system -l app.kubernetes.io/name=leveldb-app -f

# Last backup job logs
kubectl logs -n leveldb-system -l job-name -f --tail=50

# All recent events in the leveldb-system namespace
kubectl get events -n leveldb-system --sort-by=.lastTimestamp
```

Or use the provided target:

```bash
make logs
make status
```

---

## Iterating on dashboards

Grafana dashboard JSON files are in `charts/leveldb-app/dashboards/`. When you edit a dashboard JSON and run `make deploy`, Grafana reloads the dashboard via its provisioning mechanism within approximately 60 seconds.

To edit a dashboard interactively in Grafana and export it:

1. `make port-forward`
2. Open `http://localhost:3000`
3. Edit the dashboard
4. Export as JSON (Dashboard settings → JSON model)
5. Replace the corresponding file in `charts/leveldb-app/dashboards/`

---

## Teardown

```bash
make destroy    # delete the k3d cluster and all resources
```

This is irreversible. Any data not backed up externally will be lost.

---

## Common issues

**PVC stays Pending:**
k3d's `local-path` provisioner creates the PV on first pod mount. The PVC will remain `Pending` until the pod is scheduled and starts.

**Image not found in cluster:**
If you built a local image, you must import it with `k3d image import`. k3d cannot pull images marked `pullPolicy: Never` from a local Docker daemon directly.

**LevelDB lock file left after crash:**
If the app pod crashes and the LevelDB `LOCK` file is not released, the pod will fail to start. Identify and delete the lock file:

```bash
kubectl exec -n leveldb-system leveldb-app-0 -- rm /data/leveldb/LOCK
```
Then restart the pod:
```bash
kubectl delete pod -n leveldb-system leveldb-app-0
```

**Port-forward dies silently:**
`kubectl port-forward` exits if the target pod restarts. Rerun `make port-forward` after a pod restart.
