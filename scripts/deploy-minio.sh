#!/usr/bin/env bash
# deploy-minio.sh — deploy MinIO into the minio-system namespace via the
# official Helm chart and verify the Restic backup bucket is provisioned.
# Safe to rerun: helm upgrade --install is idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

HELM_RELEASE="minio"
HELM_CHART="minio/minio"
HELM_REPO_NAME="minio"
HELM_REPO_URL="https://charts.min.io/"
VALUES_FILE="${REPO_ROOT}/helm-values/minio.yaml"
VERIFY_JOB="minio-ensure-restic-bucket"
MINIO_SVC="http://minio.${NS_MINIO}.svc.cluster.local:9000"
MINIO_MC_IMAGE="${MINIO_MC_IMAGE:-minio/mc:RELEASE.2025-08-13T08-35-41Z}"

printf '%s\n' '' "=== stateful-k8s-recovery-lab: deploy MinIO ==="

section "Prerequisites"

require kubectl
require helm

section "Cluster"

if ! cluster_exists; then
    die "Cluster '${CLUSTER_NAME}' does not exist. Run: make bootstrap"
fi
ok "Cluster '${CLUSTER_NAME}' exists"

if ! kubectl cluster-info &>/dev/null 2>&1; then
    die "kubectl cannot reach the cluster. Check context: kubectl config current-context"
fi
ok "kubectl can reach the cluster"

section "Namespace"

if kubectl get namespace "${NS_MINIO}" &>/dev/null 2>&1; then
    ok "Namespace '${NS_MINIO}' already exists"
else
    kubectl create namespace "${NS_MINIO}" >/dev/null
    ok "Namespace '${NS_MINIO}' created"
fi

section "Helm repo"

if helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${HELM_REPO_NAME}"; then
    info "Helm repo '${HELM_REPO_NAME}' already present -- updating"
    helm repo update "${HELM_REPO_NAME}" >/dev/null
    ok "Helm repo '${HELM_REPO_NAME}' updated"
else
    info "Adding Helm repo '${HELM_REPO_NAME}' (${HELM_REPO_URL}) ..."
    helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null
    helm repo update "${HELM_REPO_NAME}" >/dev/null
    ok "Helm repo '${HELM_REPO_NAME}' added"
fi

section "MinIO"

info "Running: helm upgrade --install ${HELM_RELEASE} ${HELM_CHART} ..."
helm upgrade --install "${HELM_RELEASE}" "${HELM_CHART}" \
    --namespace "${NS_MINIO}" \
    --values "${VALUES_FILE}" \
    --wait \
    --timeout 5m
ok "Helm release '${HELM_RELEASE}' deployed"

section "Rollout"

if kubectl get deployment "${HELM_RELEASE}" --namespace "${NS_MINIO}" &>/dev/null 2>&1; then
    info "Detected Deployment/${HELM_RELEASE} -- waiting for deployment rollout ..."
    kubectl rollout status deployment/"${HELM_RELEASE}" \
        --namespace "${NS_MINIO}" \
        --timeout=5m >/dev/null
elif kubectl get statefulset "${HELM_RELEASE}" --namespace "${NS_MINIO}" &>/dev/null 2>&1; then
    info "Detected StatefulSet/${HELM_RELEASE} -- waiting for statefulset rollout ..."
    kubectl rollout status statefulset/"${HELM_RELEASE}" \
        --namespace "${NS_MINIO}" \
        --timeout=5m >/dev/null
else
    info "No Deployment or StatefulSet named '${HELM_RELEASE}' found -- waiting for pod readiness via release label ..."
    kubectl wait pod \
        --namespace "${NS_MINIO}" \
        --selector "release=${HELM_RELEASE}" \
        --for=condition=Ready \
        --timeout=5m >/dev/null
fi
ok "MinIO is ready"

section "Bucket"

info "Removing any previous '${VERIFY_JOB}' Job ..."
kubectl delete job "${VERIFY_JOB}" --namespace "${NS_MINIO}" --ignore-not-found >/dev/null

info "MinIO client image: ${MINIO_MC_IMAGE}"
info "Creating Job '${VERIFY_JOB}' to ensure bucket 'restic' exists ..."
kubectl create -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${VERIFY_JOB}
  namespace: ${NS_MINIO}
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: mc
          image: ${MINIO_MC_IMAGE}
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: minio
                  key: rootUser
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: minio
                  key: rootPassword
          command:
            - sh
            - -c
            - |
              mc alias set local ${MINIO_SVC} "\$MINIO_ROOT_USER" "\$MINIO_ROOT_PASSWORD" &&
              mc mb --ignore-existing local/restic &&
              mc ls local &&
              mc stat local/restic
EOF

info "Waiting for Job '${VERIFY_JOB}' to complete (timeout: 2m) ..."
if ! kubectl wait "job/${VERIFY_JOB}" \
    --namespace "${NS_MINIO}" \
    --for=condition=complete \
    --timeout=2m >/dev/null; then
    warn "Bucket verification Job did not complete -- logs:"
    kubectl logs "job/${VERIFY_JOB}" \
        --namespace "${NS_MINIO}" \
        --all-containers=true 2>&1 || true
    die "Bucket 'restic' could not be verified. Check MinIO credentials and connectivity."
fi

info "Job '${VERIFY_JOB}' logs:"
kubectl logs "job/${VERIFY_JOB}" \
    --namespace "${NS_MINIO}" \
    --all-containers=true 2>/dev/null || true
ok "Restic bucket 'restic' exists"

printf '%s\n' \
    '' \
    "MinIO is deployed in namespace '${NS_MINIO}'." \
    '' \
    'Port-forward access:' \
    "  make port-forward TARGET=minio-api      # MinIO API (S3)  -> http://localhost:9000" \
    "  make port-forward TARGET=minio-console  # MinIO Console   -> http://localhost:9001" \
    '' \
    'Credentials (local demo only -- do not reuse outside this cluster):' \
    '  User:     minioadmin' \
    '  Password: minioadmin' \
    '  Source:   helm-values/minio.yaml' \
    '' \
    'Next step:' \
    '  make status' \
    ''
