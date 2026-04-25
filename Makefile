# stateful-k8s-recovery-lab
# Run 'make help' to see all available targets.

.DEFAULT_GOAL := help

.PHONY: help check-prereqs install-prereqs install-docker \
        bootstrap deploy deploy-minio deploy-observability \
        seed-data smoke-test \
        backup backup-status suspend-backups resume-backups restore \
        logs status port-forward port-forward-all port-forward-stop \
        destroy \
        test-app run-app-local \
        demo demo-full

help: ## Show available targets and descriptions
	@awk 'BEGIN {FS = ":.*?## "}; \
	     /^##@/  { printf "\n%s\n", substr($$0,5) }; \
	     /^[a-zA-Z_-]+:.*?## / { printf "  %-24s %s\n", $$1, $$2 }' \
	     $(MAKEFILE_LIST)
	@printf '\n'

##@ Demo

demo: ## Run the core end-to-end demo (app + MinIO + backup, no observability)
	@bash scripts/demo.sh

demo-full: ## Run the full demo including Prometheus, Grafana, Loki (~10-15 min first run)
	@bash scripts/demo-full.sh

##@ App

test-app: ## Run Go unit tests for the app
	@bash scripts/test-app.sh

run-app-local: ## Run the app locally (DATA_DIR=.local/leveldb, PORT=18081)
	@bash scripts/run-app-local.sh

##@ Setup

check-prereqs: ## Verify that all required tools are installed and working
	@bash scripts/check-prereqs.sh

install-prereqs: ## Install kubectl, helm, k3d, restic, and other CLI tools (no Docker)
	@bash scripts/install-prereqs.sh

install-docker: ## Install Docker Engine on Ubuntu/Debian (requires sudo)
	@bash scripts/install-docker.sh

##@ Cluster

bootstrap: ## Create the k3d cluster and set up namespaces
	@bash scripts/bootstrap.sh

destroy: ## Delete the k3d cluster and all resources (irreversible)
	@bash scripts/destroy.sh

##@ Deploy

deploy: ## Deploy the leveldb-app StatefulSet via Helm
	@bash scripts/deploy.sh

deploy-minio: ## Deploy MinIO backup backend via Helm
	@bash scripts/deploy-minio.sh

deploy-observability: ## Deploy Prometheus, Grafana, Alertmanager, and Loki via Helm
	@bash scripts/deploy-observability.sh

##@ Data

seed-data: ## Write sample key-value pairs to establish a known baseline
	@bash scripts/seed-data.sh

smoke-test: ## Run end-to-end sanity checks against the running cluster
	@bash scripts/smoke-test.sh

##@ Backup

backup: ## Trigger a one-off backup Job from the CronJob spec
	@bash scripts/backup.sh

backup-status: ## Print the status and logs of the most recent backup Job
	@bash scripts/backup-status.sh

suspend-backups: ## Suspend the backup CronJob (pauses scheduled backups)
	@bash scripts/suspend-backups.sh

resume-backups: ## Resume the backup CronJob (re-enables scheduled backups)
	@bash scripts/resume-backups.sh

restore: ## Run the guided restore: scale down, restore snapshot, verify, scale up
	@bash scripts/restore.sh

##@ Operate

logs: ## Tail app and recent backup/restore Job logs
	@bash scripts/logs.sh

status: ## Print cluster, StatefulSet, PVC, and CronJob status summary
	@bash scripts/status.sh

port-forward: ## Forward one service locally (TARGET=app|minio-api|minio-console|grafana|prometheus|alertmanager)
	@bash scripts/port-forward.sh

port-forward-all: ## Start all available port-forwards in the background
	@bash scripts/port-forward-all.sh

port-forward-stop: ## Stop all tracked background port-forwards
	@bash scripts/port-forward-stop.sh
