# A thin dispatcher over the numbered runbook scripts. Holds NO logic, versions or values: every target just
# runs the step script it names, so `make install-cilium` and running lib/shell/01_cilium.sh by hand are
# identical. `make help` lists everything; the one-shot orchestrators are bootstrap-cluster and
# rebuild-cluster. Everything here assumes a cluster the OS repo already built:
#   https://github.com/yama6a/talos-raspberry-pi5-cluster

.DEFAULT_GOAL := help

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Cluster lifecycle  (DANGEROUS: destructive; each prompts for a typed confirmation)
.PHONY: bootstrap-cluster
bootstrap-cluster: ## DANGER: first-time platform install onto an existing cluster (CNI -> ArgoCD -> everything).
	bash lib/shell/DANGEROUS_bootstrap_cluster.sh

.PHONY: rebuild-cluster
rebuild-cluster: ## DANGER: redeliver the whole platform + WIPE the S3 backups (restores the sealed-secrets key). Does not touch the nodes.
	bash lib/shell/DANGEROUS_rebuild_cluster.sh



##@ Cluster delivery  (step 01-06; native helm/kubectl)
.PHONY: install-cilium
install-cilium: ## 01: install/upgrade the Cilium CNI (+ monitoring CRDs, LB-IPAM/L2, Hubble).
	bash lib/shell/01_cilium.sh

.PHONY: install-argocd
install-argocd: ## 02a: bootstrap ArgoCD; it then delivers the whole platform from git.
	bash lib/shell/02a_argocd.sh

.PHONY: configure-argocd-webhook
configure-argocd-webhook: ## 02b: generate+seal the ArgoCD GitHub webhook secret (-> secrets/) + set poll cadence from .env.
	bash lib/shell/02b_argocd_webhook.sh

.PHONY: configure-values
configure-values: ## 04: write every per-deployment value (repo URL, domains, SSO allowlist, ingress IP, ACME, scrape endpoints) from .env into the chart values.
	bash lib/shell/04_values.sh

.PHONY: configure-cloudflare-token
configure-cloudflare-token: ## 04: seal the Cloudflare DNS-01 API token into cert-manager (needs the sealed-secrets controller + .env token).
	bash lib/shell/04_cloudflare_token.sh

.PHONY: configure-sso
configure-sso: ## 04: write the SSO clientID + seal the OAuth client secret (needs .env creds).
	bash lib/shell/04_google_sso.sh

.PHONY: configure-ntfy-auth
configure-ntfy-auth: ## 06: seed ntfy users/ACLs + seal Grafana's ntfy write token (needs 05_ntfy synced + .env secret).
	bash lib/shell/06_ntfy_auth.sh

##@ Backups  (step 10a-10e; S3 bucket via Terraform + CNPG WAL/base + Redis RDB + Longhorn volume + VM/VL export backups)
.PHONY: s3-backup-bucket
s3-backup-bucket: ## 10a: create/update the shared S3 backup bucket + scoped IAM writer (Terraform; needs .env AWS creds).
	bash lib/shell/10a_s3_backup_bucket.sh

.PHONY: s3-backup-wipe
s3-backup-wipe: ## 10a: DANGER delete ALL backups in the bucket, keeping the bucket + IAM (typed confirm).
	bash lib/shell/10a_s3_backup_bucket.sh wipe

.PHONY: s3-backup-destroy
s3-backup-destroy: ## 10a: DANGER empty the bucket AND terraform-destroy it + the IAM writer (typed confirm).
	bash lib/shell/10a_s3_backup_bucket.sh destroy

.PHONY: configure-cnpg-backup
configure-cnpg-backup: ## 10b: enable CNPG S3 backups: seal the writer creds + write bucket/region/RPO into pg-cluster.
	bash lib/shell/10b_cnpg_backup.sh

.PHONY: configure-redis-backup
configure-redis-backup: ## 10c: enable Redis RDB S3 backups: seal the writer creds + write bucket/region into 07_redis_backup.
	bash lib/shell/10c_redis_backup.sh

.PHONY: configure-longhorn-backup
configure-longhorn-backup: ## 10d: enable Longhorn volume S3 backups: seal the writer creds + write the backup target into 02_longhorn.
	bash lib/shell/10d_longhorn_backup.sh

.PHONY: configure-vm-backup
configure-vm-backup: ## 10e: enable VictoriaMetrics/Logs S3 export backups: seal the writer creds + write bucket/region into 08_vm_backup.
	bash lib/shell/10e_vm_backup.sh

##@ Secrets  (sealed-secrets master key)
.PHONY: backup-secrets-key
backup-secrets-key: ## 03: back up the sealed-secrets master key (do this BEFORE a rebuild).
	bash lib/shell/03_backup_sealed_secrets_key.sh

.PHONY: restore-secrets-key
restore-secrets-key: ## 03: restore the sealed-secrets master key so committed SealedSecrets decrypt.
	bash lib/shell/03_restore_sealed_secrets_key.sh

##@ Node lifecycle  (the platform half of what the OS repo's node operations leave behind)
.PHONY: reconcile-storage
reconcile-storage: ## After the OS repo's `make recover-node`: drop a rejoined node's stale replicas and reset its Longhorn disk record. NODE=<hostname>, add YES=1 to skip the prompt.
	@test -n "$(NODE)" || { echo "usage: make reconcile-storage NODE=talos-cp3 [YES=1]"; exit 1; }
	bash lib/shell/reconcile_storage_after_rejoin.sh $(NODE) $(if $(YES),--yes,)

.PHONY: check-replication-health
check-replication-health: ## Are Longhorn, CNPG and RabbitMQ all healthy + in sync? Exits non-zero if not. Point the OS repo's PRE_DRAIN_HEALTH_HOOK at this.
	bash lib/shell/check_replication_health.sh

##@ Data recovery  (restore from S3: CNPG + Redis + Longhorn + VM/VL. A GitOps-pruned CNPG cluster is not deleted; just restore its files.)
.PHONY: restore-cnpg
restore-cnpg: ## Restore a CNPG database from S3, latest or PITR: in-place under its own name, or into a throwaway side cluster (interactive, resumable).
	bash lib/shell/recover_cnpg_from_s3.sh

.PHONY: restore-redis
restore-redis: ## Restore a Redis instance from its S3 RDB dump: pick a dump, replay in-place via a seed pod + replication (interactive, destructive).
	bash lib/shell/recover_redis_from_s3.sh

.PHONY: restore-longhorn
restore-longhorn: ## Restore a Longhorn volume from S3 into a new Volume + PV/PVC (interactive; needs backups on).
	bash lib/shell/recover_longhorn_from_s3.sh

.PHONY: restore-vm
restore-vm: ## Restore VictoriaMetrics/Logs from an S3 export: stream it into the live store via a temp pod (interactive; needs backups on).
	bash lib/shell/recover_vm_from_s3.sh

.PHONY: fix-chart-locks
fix-chart-locks: ## Regenerate any stale Chart.lock (out of sync with Chart.yaml) across all charts; no git.
	bash lib/shell/fix_chart_locks.sh

##@ Health & inspection  (read-only)
.PHONY: view-credentials
view-credentials: ## Print login URLs + credentials (RabbitMQ, ntfy phone, GitHub webhook) and the SSO-only UI URLs.
	bash lib/shell/view_credentials.sh

.PHONY: krr
krr: ## Rightsizing: dockerized KRR vs vmsingle (port-forward); prints request->recommended per workload (table).
	bash lib/shell/krr.sh

.PHONY: krr-json
krr-json: ## Rightsizing: same as `krr` but emits JSON.
	bash lib/shell/krr.sh -f json

.PHONY: krr-yaml
krr-yaml: ## Rightsizing: same as `krr` but emits YAML.
	bash lib/shell/krr.sh -f yaml

.PHONY: check-multiarch
check-multiarch: ## Check every running image has a manifest for every architecture in the cluster. ARCH="amd64" to check before adding such a node.
	bash lib/shell/check_multiarch.sh

##@ Benchmarks  (NOT read-only: create a throwaway namespace and load the live cluster for hours)

.PHONY: storage-bench
storage-bench: ## Measure write latency of Longhorn r2 with a local replica vs both over the network; prints p50/p95/p99.
	bash lib/shell/storage_bench.sh run

.PHONY: storage-bench-fio
storage-bench-fio: ## Same, fio fsync only: the fast (~1h) read on the question, no CNPG or RabbitMQ.
	bash lib/shell/storage_bench.sh run --workload fio

.PHONY: storage-bench-sync
storage-bench-sync: ## What SYNCHRONOUS replication costs CNPG on longhorn r2 (~45min): the price of highAvailability.
	bash lib/shell/storage_bench.sh run --workload pgsync --repeats 2

.PHONY: storage-bench-teardown
storage-bench-teardown: ## Remove everything the benchmark created (namespace, bench StorageClasses, node tags, operator CNP).
	bash lib/shell/storage_bench.sh teardown
