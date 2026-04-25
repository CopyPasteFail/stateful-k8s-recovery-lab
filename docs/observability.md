# Observability

This document describes the monitoring, alerting, logging, and dashboarding setup for `stateful-k8s-recovery-lab`.

---

## Stack

| Component | Chart | Namespace | Purpose |
|---|---|---|---|
| Prometheus | `prometheus-community/kube-prometheus-stack` | `observability` | Metrics collection, recording rules, alert evaluation |
| Grafana | Bundled with `kube-prometheus-stack` | `observability` | Dashboards, log visualization |
| Alertmanager | Bundled with `kube-prometheus-stack` | `observability` | Alert routing and deduplication |
| Loki | `grafana/loki` (SingleBinary mode) | `observability` | Log aggregation |
| Alloy | `grafana/alloy` | `observability` | DaemonSet log collector (pod logs → Loki) |

Helm values files live in `helm-values/`. Deploy the full stack with:

```bash
make deploy-observability
```

**Rationale for `kube-prometheus-stack`:** This chart bundles Prometheus, Grafana, Alertmanager, kube-state-metrics, and a curated set of Kubernetes recording rules in a single maintained release. Starting from the bundle avoids manual wiring between components. Cross-namespace ServiceMonitor discovery is enabled via `serviceMonitorSelectorNilUsesHelmValues: false` and empty selectors so that the `ServiceMonitor` in `leveldb-system` is picked up automatically.

**Rationale for Loki over a full ELK stack:** Loki indexes only log labels, not full log text, which makes it significantly cheaper to operate. Grafana queries both Prometheus (metrics) and Loki (logs) in the same UI, reducing context switching during incident investigation.

---

## Accessing the stack locally

Run the aggregate target to start every available local access point in the background:

```bash
make port-forward-all
```

The command prints local-demo credentials for UIs that require login, including Grafana and MinIO Console when they are available.

Stop them later with:

```bash
make port-forward-stop
```

Run `make port-forward` with no `TARGET` to print the available targets.

| Service | Local URL |
|---|---|
| Grafana | `http://localhost:3000` |
| Prometheus | `http://localhost:9090` |
| Alertmanager | `http://localhost:9093` |

Grafana default credentials: **admin / admin** (local demo only — change before exposing Grafana externally). The deploy script also prints the credentials from the Kubernetes Secret after deployment.

---

## Application metrics

`leveldb-app` exposes Prometheus metrics at `GET /metrics`. The actual metric names exported by the Go application are:

| Metric | Type | Description |
|---|---|---|
| `http_requests_total` | Counter | HTTP requests by `method` and `status` |
| `http_request_duration_seconds` | Histogram | HTTP request latency by `method` |
| `leveldb_errors_total` | Counter | Cumulative LevelDB read/write/open errors by `type` |
| `app_ready` | Gauge | 1 when `/readyz` returns 200; 0 otherwise |

Prometheus scrapes the app pod using a `ServiceMonitor` resource (provisioned by the Helm chart, in the `leveldb-system` namespace). The `jobLabel: app.kubernetes.io/name` field in the ServiceMonitor causes the Prometheus `job` label to be set to `leveldb-app`, which is what all dashboard queries and alert rules use.

---

## Backup and restore observability

Backup Jobs do not push metrics directly. Instead, the `PrometheusRule` uses **kube-state-metrics** (bundled with `kube-prometheus-stack`) to derive backup health from Kubernetes Job objects:

| kube-state-metrics metric | Description |
|---|---|
| `kube_job_status_failed` | Non-zero when a Job's `status.failed` count is > 0 |
| `kube_job_status_active` | Non-zero while a Job is running |
| `kube_job_status_completion_time` | Unix timestamp of successful Job completion |

This avoids the complexity of a Prometheus Pushgateway while still providing timely alerting on backup failures and staleness.

---

## Alert rules

Alert rules are defined in `charts/leveldb-app/templates/prometheusrule.yaml` and deployed as a `PrometheusRule` resource alongside the app.

### Application alerts

| Alert | Expression | For | Severity |
|---|---|---|---|
| `LevelDBAppDown` | `up{job="leveldb-app"} == 0` | 2m | critical |
| `LevelDBAppNotReady` | `app_ready{job="leveldb-app"} == 0` | 2m | warning |
| `LevelDBHighErrorRate` | `rate(leveldb_errors_total{job="leveldb-app"}[5m]) > 0` | 5m | warning |

- **LevelDBAppDown** fires when Prometheus cannot scrape the app endpoint (pod crashed, evicted, or pending).
- **LevelDBAppNotReady** fires when the app's `/readyz` endpoint is returning non-200 (e.g., LevelDB failed to open after a restore).
- **LevelDBHighErrorRate** fires when LevelDB operation errors are continuous — may indicate a corrupted database or a full disk.

### Backup alerts

| Alert | Expression | For | Severity |
|---|---|---|---|
| `LevelDBBackupJobFailed` | `kube_job_status_failed{namespace="leveldb-system", job_name=~"leveldb-app-backup-.*"} > 0` | 0m | critical |
| `LevelDBBackupNotRunRecently` | `absent(kube_job_status_completion_time{...}) or time()-max(...) > 28800` | 0m | warning |

- **LevelDBBackupJobFailed** fires immediately when any backup Job records a failure in its status.
- **LevelDBBackupNotRunRecently** fires when no backup Job has completed successfully in the last 8 hours, or when no completion timestamp exists at all (first deploy or all jobs purged).

### Storage alerts

These rules use kubelet volume stats and kube-state-metrics (both bundled with `kube-prometheus-stack`) — no custom exporter is required. The PVC name `data-leveldb-app-0` is rendered dynamically from the Helm release name at deploy time.

| Alert | Expression | For | Severity |
|---|---|---|---|
| `LevelDBPVCUsageHigh` | `kubelet_volume_stats_used_bytes{persistentvolumeclaim="data-leveldb-app-0"} / kubelet_volume_stats_capacity_bytes{...} > 0.80` | 15m | warning |
| `LevelDBPVCUsageCritical` | `kubelet_volume_stats_used_bytes{persistentvolumeclaim="data-leveldb-app-0"} / kubelet_volume_stats_capacity_bytes{...} > 0.90` | 5m | critical |
| `LevelDBPVCInodesLow` | `kubelet_volume_stats_inodes_free{persistentvolumeclaim="data-leveldb-app-0"} / kubelet_volume_stats_inodes{...} < 0.10` | 15m | warning |
| `LevelDBPVCPending` | `kube_persistentvolumeclaim_status_phase{persistentvolumeclaim="data-leveldb-app-0", phase="Bound"} == 0` | 5m | critical |

- **LevelDBPVCUsageHigh** fires when the PVC has been more than 80% full for 15 minutes. Expand the PVC or prune data before it reaches the critical threshold.
- **LevelDBPVCUsageCritical** fires when the PVC has been more than 90% full for 5 minutes. Immediate expansion is required to prevent LevelDB write failures.
- **LevelDBPVCInodesLow** fires when fewer than 10% of inodes remain for 15 minutes. LevelDB creates many small SST files during compaction; inode exhaustion will cause write failures even when bytes remain available.
- **LevelDBPVCPending** fires when the PVC is not in `Bound` phase for 5 minutes. The StatefulSet pod will remain `Pending` until the PVC is bound; check StorageClass provisioner logs or available capacity.

---

## Dashboard

The `LevelDB App Overview` dashboard is provisioned automatically via the Grafana sidecar. The JSON definition lives in `charts/leveldb-app/dashboards/leveldb-app-overview.json` and is loaded via a `ConfigMap` with the label `grafana_dashboard: "1"` (matched by the Grafana sidecar's `searchNamespace: ALL` configuration).

Dashboard UID: `leveldb-app-overview`

### Panels

| Panel | Type | Query |
|---|---|---|
| HTTP Request Rate | timeseries | `sum by (method, status) (rate(http_requests_total{job="leveldb-app"}[2m]))` |
| HTTP Request Latency | timeseries | p50/p95/p99 histogram quantiles of `http_request_duration_seconds` |
| App Readiness | stat | `app_ready{job="leveldb-app"}` — green = Ready, red = Not Ready |
| LevelDB Errors (1 h) | stat | `sum(increase(leveldb_errors_total{job="leveldb-app"}[1h]))` — green = 0, red ≥ 1 |
| Failed Backup Jobs | stat | `sum(kube_job_status_failed{namespace="leveldb-system", job_name=~"leveldb-app-backup-.*"})` |
| Active Backup Jobs | stat | `sum(kube_job_status_active{namespace="leveldb-system", job_name=~"leveldb-app-backup-.*"})` |
| HTTP Error Rate % | timeseries | Percentage of 5xx responses over total requests |
| LevelDB Error Rate | timeseries | `rate(leveldb_errors_total{job="leveldb-app"}[2m])` by error type |

---

## Log aggregation

Alloy (deployed as a DaemonSet) collects pod logs via the Kubernetes API and ships them to Loki at:

```
http://loki.observability.svc.cluster.local:3100/loki/api/v1/push
```

Loki runs in SingleBinary mode with filesystem storage — suitable for the local POC, not for production. In production, use object storage (S3 or GCS) and the SimpleScalable or Distributed deployment mode.

### Useful Loki queries

```logql
# All app logs
{namespace="leveldb-system", app_kubernetes_io_name="leveldb-app"}

# Error-level logs only (if app emits structured JSON logs)
{namespace="leveldb-system", app_kubernetes_io_name="leveldb-app"} | json | level="error"

# Backup job logs
{namespace="leveldb-system"} |= "backup"

# Restore job logs
{namespace="leveldb-system", app_kubernetes_io_component="restore"}

# All logs in the observability namespace
{namespace="observability"}
```

---

## Tail logs from the CLI

```bash
make logs
```

Streams the last 100 lines and follows new output from the app pod, recent backup Jobs, and recent restore Jobs.

---

## Alertmanager routing

In the local POC, Alertmanager uses a null receiver — alerts are visible at `http://localhost:9093` but are not forwarded to any external system. This is configured in `helm-values/kube-prometheus-stack.yaml`:

```yaml
alertmanager:
  config:
    route:
      receiver: 'null'
    receivers:
      - name: 'null'
```

For production, replace with external receivers:

```yaml
alertmanager:
  config:
    route:
      receiver: pagerduty-critical
      routes:
        - match: { severity: critical }
          receiver: pagerduty-critical
        - match: { severity: warning }
          receiver: slack-warnings
    receivers:
      - name: pagerduty-critical
        pagerduty_configs:
          - service_key: <secret>
      - name: slack-warnings
        slack_configs:
          - api_url: <secret>
            channel: '#alerts'
```

### Expected local-demo alert noise

When running `kube-prometheus-stack` in local k3d, some upstream Kubernetes control-plane alerts may fire even though the demo itself is healthy. Based on the current local cluster, the following alerts are expected noise:

| Alert | Source | Classification | Why it can fire locally |
|---|---|---|---|
| `Watchdog` | `general.rules` | kube-prometheus default noise | This alert is designed to always fire so the alert pipeline stays exercised. |
| `KubeControllerManagerDown` | `kubernetes-system-controller-manager` | kube-prometheus default noise | Local k3d clusters typically do not expose a reachable controller-manager target to Prometheus. |
| `KubeProxyDown` | `kubernetes-system-kube-proxy` | kube-prometheus default noise | Local k3d setups often do not expose kube-proxy as a scrape target in the same way as a managed cluster. |
| `KubeSchedulerDown` | `kubernetes-system-scheduler` | kube-prometheus default noise | Local k3d setups often do not expose kube-scheduler as a scrape target in the same way as a managed cluster. |

These alerts are useful to show that Prometheus and Alertmanager are working, but they should not be treated as app, backup, MinIO, or storage failures in this demo.

The current Alertmanager UI state is also expected for the local demo:

- `Cluster Status: disabled` is normal for a single local Alertmanager instance without clustering.
- `receiver: "null"` is normal because the local demo keeps alerts visible in the UI but does not forward them externally.

---

## Troubleshooting

### Alloy pod is CrashLoopBackOff or not collecting logs

Check pod logs first:

```bash
kubectl -n observability logs daemonset/alloy --tail=40
```

**`too many open files` / inotify limit exceeded** — Alloy's Kubernetes log discovery opens inotify watches. If `max_user_instances` is too low the pod crashes on start. Fix:

```bash
# Apply immediately (lost on reboot)
sudo sysctl -w fs.inotify.max_user_instances=512

# Persist across reboots
echo 'fs.inotify.max_user_instances=512' | sudo tee /etc/sysctl.d/99-k3d-inotify.conf
echo 'fs.inotify.max_user_watches=524288' | sudo tee -a /etc/sysctl.d/99-k3d-inotify.conf
sudo sysctl -p /etc/sysctl.d/99-k3d-inotify.conf

# Delete the crashed pod so the DaemonSet recreates it with the new limit
kubectl -n observability delete pod -l app.kubernetes.io/name=alloy
```

`make install-prereqs` writes this configuration automatically.

**No logs appearing in Grafana / Loki** — verify Alloy is pushing to Loki:

```bash
kubectl -n observability port-forward svc/loki 3100:3100 &
curl -s 'http://localhost:3100/loki/api/v1/labels' | jq .
```

If the `namespace` label is present, Loki is receiving data. If not, check that the Alloy config in `helm-values/alloy.yaml` uses the correct Loki push URL.

### No data in Prometheus / metrics not appearing

Verify the ServiceMonitor exists and Prometheus has picked it up:

```bash
kubectl -n leveldb-system get servicemonitor
kubectl -n observability port-forward svc/prometheus-operated 9090:9090 &
# Then open http://localhost:9090/targets
```

If the `leveldb-app` target is missing, ensure `MONITORING=1 make deploy` was run after `make deploy-observability`. Without `MONITORING=1`, the ServiceMonitor and PrometheusRule are not created.

---

## Observability for the restore workflow

The restore script (`scripts/restore.sh`) emits structured log output to stdout that Alloy collects and ships to Loki. After a restore, inspect what happened with:

```logql
{namespace="leveldb-system", app_kubernetes_io_component="restore"}
```

The `LevelDBBackupNotRunRecently` alert fires if the CronJob remains suspended after a restore for more than 8 hours, acting as a reminder to run `make resume-backups`.

The `LevelDBAppNotReady` alert fires if the app fails to start successfully after the restore (e.g., data directory permissions issue or a corrupt snapshot), providing an early signal before users notice.
