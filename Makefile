# A thin dispatcher over lib/shell. It holds no logic, versions or values.

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Cluster lifecycle: destructive. Each target asks for a typed confirmation
.PHONY: bootstrap-cluster
bootstrap-cluster: ## DANGER: first platform install on an existing cluster. The CNI, then Argo CD, then everything else.
	bash lib/shell/DANGEROUS_bootstrap_cluster.sh

.PHONY: rebuild-cluster
rebuild-cluster: ## DANGER: redeliver the whole platform and wipe the S3 backups. Restores the sealed-secrets key. Does not touch the nodes.
	bash lib/shell/DANGEROUS_rebuild_cluster.sh



##@ Cluster delivery: steps 01 to 06, with native helm and kubectl
.PHONY: install-cilium
install-cilium: ## 01: install or upgrade the Cilium CNI, with the monitoring CRDs, LB-IPAM, L2 announcements and Hubble.
	bash lib/shell/01_cilium.sh

.PHONY: install-argocd
install-argocd: ## 02a: bootstrap Argo CD. Argo CD then delivers the whole platform from git.
	bash lib/shell/02a_argocd.sh

.PHONY: configure-argocd-webhook
configure-argocd-webhook: ## 02b: generate the Argo CD GitHub webhook secret into secrets/ and seal it. Sets the poll interval from .env.
	bash lib/shell/02b_argocd_webhook.sh

.PHONY: configure-values
configure-values: ## 04: write every per-deployment value from .env into the chart values.
	bash lib/shell/04_values.sh

.PHONY: configure-cloudflare-token
configure-cloudflare-token: ## 04: seal the Cloudflare DNS-01 API token into cert-manager. Needs the sealed-secrets controller and the .env token.
	bash lib/shell/04_cloudflare_token.sh

.PHONY: configure-sso
configure-sso: ## 04: write the SSO client ID and seal the OAuth client secret. Needs the .env creds.
	bash lib/shell/04_google_sso.sh

.PHONY: configure-ntfy-auth
configure-ntfy-auth: ## 06: seed the ntfy users and ACLs, and seal Grafana's ntfy write token. Needs 05_ntfy synced and the .env secret.
	bash lib/shell/06_ntfy_auth.sh

##@ Backups: steps 10a to 10e. The S3 bucket, then CNPG, Redis, Longhorn and VictoriaMetrics/Logs backups
.PHONY: s3-backup-bucket
s3-backup-bucket: ## 10a: create or update the shared S3 backup bucket and scoped IAM writer with Terraform. Needs the .env AWS creds.
	bash lib/shell/10a_s3_backup_bucket.sh

.PHONY: s3-backup-wipe
s3-backup-wipe: ## 10a: DANGER: delete every backup in the bucket. Keeps the bucket and IAM writer. Asks for a typed confirmation.
	bash lib/shell/10a_s3_backup_bucket.sh wipe

.PHONY: s3-backup-destroy
s3-backup-destroy: ## 10a: DANGER: empty the bucket, then terraform destroy it and the IAM writer. Asks for a typed confirmation.
	bash lib/shell/10a_s3_backup_bucket.sh destroy

.PHONY: configure-cnpg-backup
configure-cnpg-backup: ## 10b: turn on CNPG S3 backups. Seals the writer creds and writes bucket, region and RPO into pg-cluster.
	bash lib/shell/10b_cnpg_backup.sh

.PHONY: configure-redis-backup
configure-redis-backup: ## 10c: turn on Redis RDB S3 backups. Seals the writer creds and writes bucket and region into 07_redis_backup.
	bash lib/shell/10c_redis_backup.sh

.PHONY: configure-longhorn-backup
configure-longhorn-backup: ## 10d: turn on Longhorn volume S3 backups. Seals the writer creds and writes the backup target into 02_longhorn.
	bash lib/shell/10d_longhorn_backup.sh

.PHONY: configure-vm-backup
configure-vm-backup: ## 10e: turn on VictoriaMetrics/Logs S3 export backups. Seals the writer creds and writes bucket and region into 08_vm_backup.
	bash lib/shell/10e_vm_backup.sh

##@ Secrets: the sealed-secrets master key
.PHONY: backup-secrets-key
backup-secrets-key: ## 03: back up the sealed-secrets master key. Do this before a rebuild.
	bash lib/shell/03_backup_sealed_secrets_key.sh

.PHONY: restore-secrets-key
restore-secrets-key: ## 03: restore the sealed-secrets master key, so the committed SealedSecrets decrypt.
	bash lib/shell/03_restore_sealed_secrets_key.sh

##@ Node lifecycle: the platform steps before and after your node tooling acts
.PHONY: reconcile-storage
reconcile-storage: ## After a replaced machine rejoins: drop its stale replicas and reset its Longhorn disk. NODE=<hostname>, YES=1 skips the prompt.
	@test -n "$(NODE)" || { echo "usage: make reconcile-storage NODE=<hostname> [YES=1]"; exit 1; }
	bash lib/shell/reconcile_storage_after_rejoin.sh $(NODE) $(if $(YES),--yes,)

.PHONY: check-replication-health
check-replication-health: ## Check that Longhorn, CNPG and RabbitMQ are healthy and in sync. Use it as a pre-drain gate.
	bash lib/shell/check_replication_health.sh

.PHONY: evacuate-node
evacuate-node: ## Move any CNPG primary off a node before a drain. NODE=<hostname>.
	@test -n "$(NODE)" || { echo "usage: make evacuate-node NODE=<hostname>"; exit 1; }
	NODE=$(NODE) bash lib/shell/evacuate_node.sh

##@ Data recovery: restore CNPG, Redis, Longhorn and VictoriaMetrics/Logs from S3. A GitOps prune does not delete a CNPG cluster, so restore only its files
.PHONY: restore-cnpg
restore-cnpg: ## Restore a CNPG database from S3, latest or point in time. In place under its own name, or into a throwaway side cluster. Interactive and resumable.
	bash lib/shell/recover_cnpg_from_s3.sh

.PHONY: restore-redis
restore-redis: ## Restore a Redis instance from its S3 RDB dump. Pick a dump, then replay it in place through a seed pod and replication. Interactive and destructive.
	bash lib/shell/recover_redis_from_s3.sh

.PHONY: restore-longhorn
restore-longhorn: ## Restore a Longhorn volume from S3 into a new Volume, PV and PVC. Interactive. Needs backups on.
	bash lib/shell/recover_longhorn_from_s3.sh

.PHONY: restore-vm
restore-vm: ## Restore VictoriaMetrics/Logs from an S3 export. Streams it into the live store through a temporary pod. Interactive. Needs backups on.
	bash lib/shell/recover_vm_from_s3.sh

.PHONY: fix-chart-locks
fix-chart-locks: ## Regenerate every Chart.lock that is out of sync with its Chart.yaml. Does not touch git.
	bash lib/shell/fix_chart_locks.sh

##@ Storage cleanup: destructive, deletes volume data
.PHONY: cleanup-abandoned-pvs
cleanup-abandoned-pvs: ## List the PVs that nothing will bind again, Released or never claimed. Deletes the ones you pick with their Longhorn volume. Keeps the S3 backup.
	bash lib/shell/cleanup_abandoned_pvs.sh

##@ Health and inspection: read-only
.PHONY: view-credentials
view-credentials: ## Print the login URLs and credentials.
	bash lib/shell/view_credentials.sh

.PHONY: krr
krr: ## Rightsizing: run KRR against vmsingle and print request and recommendation per workload.
	bash lib/shell/krr.sh

.PHONY: krr-json
krr-json: ## Rightsizing: same as `krr`, as JSON.
	bash lib/shell/krr.sh -f json

.PHONY: krr-yaml
krr-yaml: ## Rightsizing: same as `krr`, as YAML.
	bash lib/shell/krr.sh -f yaml

.PHONY: check-multiarch
check-multiarch: ## Check that every running image has a manifest for every architecture in the cluster. Set ARCH="amd64" to check before you add such a node.
	bash lib/shell/check_multiarch.sh

##@ Benchmarks: not read-only. They create a throwaway namespace and load the live cluster for hours

.PHONY: storage-bench
storage-bench: ## Measure the write latency of Longhorn r2 with a local replica against both replicas over the network. Prints p50, p95 and p99.
	bash lib/shell/storage_bench.sh run

.PHONY: storage-bench-fio
storage-bench-fio: ## Same, with fio fsync only. The fast answer, about 1h, with no CNPG or RabbitMQ.
	bash lib/shell/storage_bench.sh run --workload fio

.PHONY: storage-bench-sync
storage-bench-sync: ## Measure what synchronous replication costs CNPG on Longhorn r2, the price of highAvailability. About 45min.
	bash lib/shell/storage_bench.sh run --workload pgsync --repeats 2

.PHONY: storage-bench-teardown
storage-bench-teardown: ## Remove everything the benchmark created: namespace, bench StorageClasses, node tags and the operator CiliumNetworkPolicy.
	bash lib/shell/storage_bench.sh teardown
