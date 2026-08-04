# A thin dispatcher over the numbered runbook scripts. Holds NO logic, versions or values: every target just
# runs the step script it names, so `make install-cilium` and running lib/shell/04_cilium.sh by hand are
# identical. `make help` lists everything; the one-shot orchestrators are bootstrap-cluster and
# rebuild-cluster. The health targets need a live cluster and a populated .env.

.DEFAULT_GOAL := help

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Cluster lifecycle  (DANGEROUS: destructive; each prompts for a typed confirmation)
.PHONY: bootstrap-cluster
bootstrap-cluster: ## DANGER: first-time init of freshly-flashed nodes -> full cluster (archives old creds).
	bash lib/shell/DANGEROUS_bootstrap_cluster.sh

.PHONY: rebuild-cluster
rebuild-cluster: ## DANGER: wipe a RUNNING cluster and rebuild end-to-end (restores the sealed-secrets key).
	bash lib/shell/DANGEROUS_rebuild_cluster.sh

.PHONY: reset-cluster
reset-cluster: ## DANGER: wipe all nodes (STATE + EPHEMERAL + Longhorn) back to maintenance.
	bash lib/shell/DANGEROUS_reset_talos_cluster.sh

##@ Node image & Talos bring-up  (step 02-03; the talos steps run their tooling in Docker)
.PHONY: build-eeprom-card
build-eeprom-card: ## 02: build a reusable SD card that flashes the Pi 5 EEPROM (boot order / PCIe probe).
	bash lib/shell/02_raspi_eeprom.sh

.PHONY: flash-talos-nvme
flash-talos-nvme: ## 03a: download the pinned Talos Pi 5 image release and write it to an NVMe SSD over USB.
	bash lib/shell/03a_talos_image_flasher.sh

.PHONY: verify-talos-boot
verify-talos-boot: ## 03b: verify freshly-flashed nodes boot into maintenance mode.
	bash lib/shell/03b_talos_boot_verify.sh

.PHONY: configure-talos
configure-talos: ## 03c: generate + apply machine config, bootstrap etcd, write kube/talosconfig.
	bash lib/shell/03c_talos_cluster_config.sh

.PHONY: harden-nics
harden-nics: ## 03d: apply NIC hardening (disable EEE / watchdog) to every node.
	bash lib/shell/03d_nic_hardening.sh

.PHONY: upgrade-talos
upgrade-talos: ## 03e: rolling in-place upgrade of the Talos OS to the pinned installer image.
	bash lib/shell/03e_talos_upgrade.sh

.PHONY: upgrade-k8s
upgrade-k8s: ## 03f: rolling in-place upgrade of Kubernetes to the pinned version.
	bash lib/shell/03f_k8s_upgrade.sh

.PHONY: rebalance-workloads
rebalance-workloads: ## 03g: rolling-restart the stateless Deployments so the scheduler re-spreads them (03e runs this).
	bash lib/shell/03g_rebalance_workloads.sh

.PHONY: recover-node
recover-node: ## 15: rejoin ONE wiped/replaced node and fix what does not self-heal. NODE=<hostname>, add YES=1 to skip the prompt.
	@test -n "$(NODE)" || { echo "usage: make recover-node NODE=pi-cp3 [YES=1]"; exit 1; }
	bash lib/shell/recover_node.sh $(NODE) $(if $(YES),--yes,)

##@ Cluster delivery  (step 04-09; native helm/kubectl)
.PHONY: install-cilium
install-cilium: ## 04: install/upgrade the Cilium CNI (+ monitoring CRDs, LB-IPAM/L2, Hubble).
	bash lib/shell/04_cilium.sh

.PHONY: install-argocd
install-argocd: ## 05: bootstrap ArgoCD; it then delivers the whole platform from git.
	bash lib/shell/05_argocd.sh

.PHONY: configure-argocd-webhook
configure-argocd-webhook: ## 08: generate+seal the ArgoCD GitHub webhook secret (-> secrets/) + set poll cadence from .env.
	bash lib/shell/08_argocd_webhook.sh

.PHONY: configure-gateway
configure-gateway: ## 07: write LE_EMAIL + Cloudflare DNS-01 zones into the gateway/ingress chart values (pure yq, no cluster).
	bash lib/shell/07_gateway.sh

.PHONY: configure-cloudflare-token
configure-cloudflare-token: ## 07: seal the Cloudflare DNS-01 API token into cert-manager (needs the sealed-secrets controller + .env token).
	bash lib/shell/07_cloudflare_token.sh

.PHONY: configure-sso
configure-sso: ## 07: write the SSO clientID + seal the OAuth client secret (needs .env creds).
	bash lib/shell/07_google_sso.sh

.PHONY: configure-ntfy-auth
configure-ntfy-auth: ## 10: seed ntfy users/ACLs + seal Grafana's ntfy write token (needs 05_ntfy synced + .env secret).
	bash lib/shell/10_ntfy_auth.sh

##@ Backups  (step 13-17; S3 bucket via Terraform + CNPG WAL/base + Redis RDB + Longhorn volume + VM/VL export backups)
.PHONY: s3-backup-bucket
s3-backup-bucket: ## 13: create/update the shared S3 backup bucket + scoped IAM writer (Terraform; needs .env AWS creds).
	bash lib/shell/13_s3_backup_bucket.sh

.PHONY: s3-backup-wipe
s3-backup-wipe: ## 13: DANGER delete ALL backups in the bucket, keeping the bucket + IAM (typed confirm).
	bash lib/shell/13_s3_backup_bucket.sh wipe

.PHONY: s3-backup-destroy
s3-backup-destroy: ## 13: DANGER empty the bucket AND terraform-destroy it + the IAM writer (typed confirm).
	bash lib/shell/13_s3_backup_bucket.sh destroy

.PHONY: configure-cnpg-backup
configure-cnpg-backup: ## 14: enable CNPG S3 backups: seal the writer creds + write bucket/region/RPO into pg-cluster.
	bash lib/shell/14_cnpg_backup.sh

.PHONY: configure-redis-backup
configure-redis-backup: ## 15: enable Redis RDB S3 backups: seal the writer creds + write bucket/region into 07_redis_backup.
	bash lib/shell/15_redis_backup.sh

.PHONY: configure-longhorn-backup
configure-longhorn-backup: ## 16: enable Longhorn volume S3 backups: seal the writer creds + write the backup target into 02_longhorn.
	bash lib/shell/16_longhorn_backup.sh

.PHONY: configure-vm-backup
configure-vm-backup: ## 17: enable VictoriaMetrics/Logs S3 export backups: seal the writer creds + write bucket/region into 08_vm_backup.
	bash lib/shell/17_vm_backup.sh

##@ Secrets  (sealed-secrets master key)
.PHONY: backup-secrets-key
backup-secrets-key: ## 06: back up the sealed-secrets master key (do this BEFORE a rebuild).
	bash lib/shell/06_backup_sealed_secrets_key.sh

.PHONY: restore-secrets-key
restore-secrets-key: ## 06: restore the sealed-secrets master key so committed SealedSecrets decrypt.
	bash lib/shell/06_restore_sealed_secrets_key.sh

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

##@ Health & inspection  (read-only; use the dockerized talosctl + the 03c kubeconfig)
.PHONY: check-health
check-health: ## Talos: wait for and report overall cluster health.
	@bash -c 'source lib/shell/common.sh && talosctl health'

.PHONY: talosctl
talosctl: ## Run dockerized talosctl, e.g. `make talosctl get members`. Any FLAG needs a `--` first: `make talosctl -- -n <ip> etcd members`.
	@bash -c 'source lib/shell/common.sh && talosctl $(filter-out $@,$(MAKECMDGOALS))'

.PHONY: print-kubeconfig
print-kubeconfig: ## Print the 03c kubeconfig export line (eval it to point your kubectl at the cluster).
	@bash -c 'source lib/shell/common.sh && echo "export KUBECONFIG=$$CLUSTER_DIR/kubeconfig"'

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

# Words after `make talosctl ...` (get, members, services, ...) are extra goals to Make; this no-op catch-all
# swallows them so they're passed to talosctl instead of erroring. Explicit targets above still take priority,
# so a mistyped real target quietly no-ops rather than erroring, the one cost of positional passthrough args.
#
# A flag never reaches talosctl on its own: Make claims it first, and `-n` is Make's own --just-print, so
# `make talosctl -n <ip> etcd members` silently prints the command instead of running it. Put a `--` before
# the first flag and Make stops parsing options: `make talosctl -- -n <ip> etcd members`.
%:
	@:
