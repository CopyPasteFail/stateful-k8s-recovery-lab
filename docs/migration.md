# Data Migration and Upgrade Procedures

This document covers procedures for migrating data, upgrading the application, and expanding storage. Each section distinguishes between local POC and production behavior.

---

## Table of contents

1. [PVC expansion](#pvc-expansion)
2. [Application version upgrade](#application-version-upgrade)
3. [Restic repository migration](#restic-repository-migration)
4. [MinIO backend migration](#minio-backend-migration)
5. [Shard addition (horizontal expansion)](#shard-addition)
6. [Kubernetes version upgrade](#kubernetes-version-upgrade)

---

## PVC expansion {#pvc-expansion}

### When to expand

Expand the PVC when `PVCUsageHigh` or `PVCUsageCritical` alerts fire, or proactively when usage trends toward 70%.

### Local POC

k3d uses the `local-path` storage provisioner, which does not support online PVC expansion. To expand storage in the local POC:

1. `make backup` — take a fresh backup
2. Scale the StatefulSet to 0
3. Delete the old PVC
4. Update the PVC size in the Helm values
5. Run `make deploy` — a new PVC is created with the larger size
6. Run `make restore` — restore data to the new PVC

This is destructive: the old PVC is deleted. Confirm backups are intact before proceeding.

### Production

If the storage class supports volume expansion (most cloud block storage classes do):

1. `make suspend-backups`
2. Patch the PVC with the new size:
   ```bash
   kubectl patch pvc data-leveldb-app-0 -n leveldb-system -p '{"spec":{"resources":{"requests":{"storage":"2Ti"}}}}'
   ```
3. Wait for the PVC to resize (the filesystem resize happens automatically with `allowVolumeExpansion: true`):
   ```bash
   kubectl get pvc data-leveldb-app-0 -n leveldb-system -w
   ```
4. `make resume-backups`
5. `make smoke-test`

No data is lost. The pod does not need to restart for most cloud storage classes (the resize is online).

---

## Application version upgrade {#application-version-upgrade}

### Upgrade procedure

1. `make backup` — take a backup of the current data
2. Update the image tag in `charts/leveldb-app/values.yaml`
3. Run `make deploy` — Helm upgrades the release, which triggers a StatefulSet rolling update
4. The StatefulSet stops the old pod, starts the new pod against the same PVC
5. `make smoke-test`

### Rollback

If `make smoke-test` fails after an upgrade:

```bash
helm rollback leveldb-app -n leveldb-system
make smoke-test
```

Helm rollback redeploys the previous chart version. The PVC is not affected by a rollback—the data on disk is whatever state the new version left it in. If the new version corrupted the LevelDB directory, a rollback alone is not sufficient; run `make restore` to recover from the last backup.

### LevelDB format compatibility

LevelDB's on-disk format is stable across versions. Application upgrades that change only the HTTP layer or business logic do not require any data migration. If an application version changes the storage schema (e.g., changes key encoding), document the migration steps explicitly and test the upgrade path before applying it to a production instance.

---

## Restic repository migration {#restic-repository-migration}

### Migrating to a new Restic version

Restic maintains backward compatibility for repository format across minor versions. When upgrading the Restic binary version in the backup Job image:

1. Test the new version against the existing repository in a non-production environment
2. Run `restic check` before and after the upgrade
3. If the new version introduces a format migration, run `restic migrate` as documented in the Restic release notes

### Migrating to a new repository location

If the MinIO bucket or backend URL changes:

1. `make suspend-backups`
2. Copy all repository data to the new location (use `restic copy` if moving between S3-compatible backends, or `aws s3 sync` for raw object copy)
3. Update the `RESTIC_REPOSITORY` value in the Helm chart
4. Run `make deploy` to propagate the new values to the CronJob and restore Job specs
5. Run `restic check` against the new repository
6. `make resume-backups`

**Do not** change the repository password during a migration. If the password must change, add the new password with `restic key add` before removing the old one.

---

## MinIO backend migration {#minio-backend-migration}

### Local MinIO to cloud S3

The local POC uses in-cluster MinIO. To migrate to AWS S3 (or another S3-compatible service):

1. `make suspend-backups`
2. Copy the Restic repository from MinIO to S3:
   ```bash
   # Run from a pod with access to both endpoints
   aws s3 sync s3://restic s3://my-production-bucket/restic \
     --source-region us-east-1 \
     --region us-east-1
   ```
   Or use Restic's native copy:
   ```bash
   restic -r s3:http://minio.minio-system.svc.cluster.local:9000/restic copy \
     --to s3:https://s3.amazonaws.com/my-production-bucket/restic
   ```
3. Update the `RESTIC_REPOSITORY` and AWS credentials in Helm values and the Kubernetes Secret
4. Run `make deploy`
5. Verify: `restic snapshots` against the new repository
6. `make resume-backups`

---

## Shard addition {#shard-addition}

### Context

The shard-per-pod scaling model runs multiple `leveldb-app` StatefulSet pods, each owning a disjoint key range. This is a client-side sharding model: the client determines which pod to route a given key to.

### Adding a shard

This is an application-level operation, not a Kubernetes operation. Steps at a high level:

1. Determine the new key range assignment (e.g., split `leveldb-app-1`'s key range in half)
2. Scale the StatefulSet to the new replica count in the Helm values
3. For the new pod's PVC: it starts empty. The client can begin routing new keys to the new shard immediately.
4. For existing keys that should migrate to the new shard: perform the key migration at the application level (read from the old shard, write to the new shard, delete from the old shard). This requires application-level support.

**There is no automatic key rebalancing.** LevelDB does not have a cluster mode. Shard addition requires explicit application-level coordination.

---

## Kubernetes version upgrade {#kubernetes-version-upgrade}

### Compatibility check

Before upgrading the Kubernetes version (applies to managed clusters):

1. Verify all API versions used in the Helm chart are still non-deprecated in the target Kubernetes version. Check `kubectl api-resources` and `kubectl explain` for any deprecation warnings.
2. Verify the storage class and CSI driver are compatible with the new Kubernetes version.
3. Test the upgrade on a non-production cluster first.

### k3d version upgrade (local POC)

k3d clusters are ephemeral. To upgrade:

1. `make backup` — ensure data is backed up
2. `make destroy` — delete the old cluster
3. Update the k3d version in `scripts/install-prereqs.sh`
4. `make bootstrap` — create a new cluster with the new k3d version
5. `make deploy && make deploy-minio && make deploy-observability`
6. `make restore` — restore data from the last backup
7. `make smoke-test`
