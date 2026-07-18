# raspi-cluster — a thin dispatcher over the numbered runbook scripts.
#
# This Makefile does NOT hold any logic, versions, or values: every target just runs the step script it
# names (which sources lib/shell/common.sh + .env and does the real work), so `make install-cilium` and running
# lib/shell/04_cilium.sh by hand are identical. See CLAUDE.md for the runbook order and conventions;
# `make help` lists everything below in one place.
#
# Run steps in runbook order (02 -> 03a..g -> 04 -> 05 ...), or use the one-shot orchestrators:
#   make bootstrap-cluster   first-time init of freshly-flashed nodes
#   make rebuild-cluster     wipe a running cluster and rebuild it end-to-end
#
# The health/inspection targets source lib/shell/common.sh for the dockerized talosctl() + the 03d kubeconfig,
# so they need a live cluster and a populated .env.

.DEFAULT_GOAL := help

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Cluster lifecycle  (DANGEROUS — destructive; each prompts for a typed confirmation)
.PHONY: bootstrap-cluster
bootstrap-cluster: ## DANGER: first-time init of freshly-flashed nodes -> full cluster (archives old creds).
	bash lib/shell/DANGEROUS_bootstrap_cluster.sh

.PHONY: rebuild-cluster
rebuild-cluster: ## DANGER: wipe a RUNNING cluster and rebuild end-to-end (restores the sealed-secrets key).
	bash lib/shell/DANGEROUS_rebuild_cluster.sh

.PHONY: reset-cluster
reset-cluster: ## DANGER: wipe all nodes (STATE + EPHEMERAL + Longhorn) back to maintenance.
	bash lib/shell/DANGEROUS_reset_talos_cluster.sh

##@ Node image & Talos bring-up  (step 02–03; image work runs in Docker)
.PHONY: build-eeprom-card
build-eeprom-card: ## 02: build a reusable SD card that flashes the Pi 5 EEPROM (boot order / PCIe probe).
	bash lib/shell/02_raspi_eeprom.sh

.PHONY: build-talos-image
build-talos-image: ## 03a: build (and optionally publish) the custom Pi 5 Talos installer image.
	bash lib/shell/03a_talos_image_builder.sh

.PHONY: flash-talos-nvme
flash-talos-nvme: ## 03b: write the built Talos image to an NVMe SSD over USB (once per drive).
	bash lib/shell/03b_talos_image_flasher.sh

.PHONY: verify-talos-boot
verify-talos-boot: ## 03c: verify freshly-flashed nodes boot into maintenance mode.
	bash lib/shell/03c_talos_boot_verify.sh

.PHONY: configure-talos
configure-talos: ## 03d: generate + apply machine config, bootstrap etcd, write kube/talosconfig.
	bash lib/shell/03d_talos_cluster_config.sh

.PHONY: harden-nics
harden-nics: ## 03e: apply NIC hardening (disable EEE / watchdog) to every node.
	bash lib/shell/03e_nic_hardening.sh

.PHONY: upgrade-talos
upgrade-talos: ## 03f: rolling in-place upgrade of the Talos OS to the pinned installer image.
	bash lib/shell/03f_talos_upgrade.sh

.PHONY: upgrade-k8s
upgrade-k8s: ## 03g: rolling in-place upgrade of Kubernetes to the pinned version.
	bash lib/shell/03g_k8s_upgrade.sh

##@ Cluster delivery  (step 04–09; native helm/kubectl)
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
configure-gateway: ## 07: write LE_EMAIL/BASE_DOMAIN into the gateway chart values.
	bash lib/shell/07_gateway.sh

.PHONY: configure-sso
configure-sso: ## 07: write the SSO clientID + seal the OAuth client secret (needs .env creds).
	bash lib/shell/07_google_sso.sh

.PHONY: configure-grafana-smtp
configure-grafana-smtp: ## 09: seal the Grafana SMTP app password (needs .env secret).
	bash lib/shell/09_grafana_smtp.sh

##@ Backups  (step 13–17; S3 bucket via Terraform + CNPG WAL/base + Redis RDB + Longhorn volume + VM/VL export backups)
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
configure-cnpg-backup: ## 14: enable CNPG S3 backups — seal the writer creds + write bucket/region/RPO into pg-cluster.
	bash lib/shell/14_cnpg_backup.sh

.PHONY: configure-redis-backup
configure-redis-backup: ## 15: enable Redis RDB S3 backups — seal the writer creds + write bucket/region into redis-instance.
	bash lib/shell/15_redis_backup.sh

.PHONY: configure-longhorn-backup
configure-longhorn-backup: ## 16: enable Longhorn volume S3 backups — seal the writer creds + write the backup target into 02_longhorn.
	bash lib/shell/16_longhorn_backup.sh

.PHONY: configure-vm-backup
configure-vm-backup: ## 17: enable VictoriaMetrics/Logs S3 export backups — seal the writer creds + write bucket/region into 08_vm_backup.
	bash lib/shell/17_vm_backup.sh

##@ Secrets  (sealed-secrets master key)
.PHONY: backup-secrets-key
backup-secrets-key: ## 06: back up the sealed-secrets master key (do this BEFORE a rebuild).
	bash lib/shell/06_backup_sealed_secrets_key.sh

.PHONY: restore-secrets-key
restore-secrets-key: ## 06: restore the sealed-secrets master key so committed SealedSecrets decrypt.
	bash lib/shell/06_restore_sealed_secrets_key.sh

##@ Data recovery  (CNPG — two tiers: reattach the retained PV, or restore from S3; Redis + Longhorn + VM/VL — restore from S3)
.PHONY: recover-cnpg
recover-cnpg: ## Reattach a deleted CNPG Cluster to its RETAINED local-path PV (fast; pauses ArgoCD, recreates the adopt PVC).
	bash lib/shell/recover_cnpg_from_pv.sh

.PHONY: restore-cnpg
restore-cnpg: ## Restore a CNPG database from S3 — latest or PITR — into a fresh cluster (interactive; needs backups on).
	bash lib/shell/recover_cnpg_from_s3.sh

.PHONY: restore-redis
restore-redis: ## Restore a Redis instance from its S3 RDB dump — in-place via a seed pod + replication (interactive, destructive).
	bash lib/shell/recover_redis_from_s3.sh

.PHONY: restore-longhorn
restore-longhorn: ## Restore a Longhorn volume from S3 into a new Volume + PV/PVC (interactive; needs backups on).
	bash lib/shell/recover_longhorn_from_s3.sh

.PHONY: restore-vm
restore-vm: ## Restore VictoriaMetrics/Logs from an S3 export — stream it into the live store via a temp pod (interactive; needs backups on).
	bash lib/shell/recover_vm_from_s3.sh

##@ Health & inspection  (read-only; use the dockerized talosctl + the 03d kubeconfig)
.PHONY: check-health
check-health: ## Talos: wait for and report overall cluster health.
	@bash -c 'source lib/shell/common.sh && talosctl health'

.PHONY: talosctl
talosctl: ## Run dockerized talosctl with args, e.g. `make talosctl get members` or `make talosctl services`.
	@bash -c 'source lib/shell/common.sh && talosctl $(filter-out $@,$(MAKECMDGOALS))'

.PHONY: print-kubeconfig
print-kubeconfig: ## Print the 03d kubeconfig export line (eval it to point your kubectl at the cluster).
	@bash -c 'source lib/shell/common.sh && echo "export KUBECONFIG=$$CLUSTER_DIR/kubeconfig"'

.PHONY: krr
krr: ## Rightsizing: dockerized KRR vs vmsingle (port-forward); prints request->recommended per workload (table).
	bash lib/shell/krr.sh

.PHONY: krr-json
krr-json: ## Rightsizing: same as `krr` but emits JSON.
	bash lib/shell/krr.sh -f json

.PHONY: krr-yaml
krr-yaml: ## Rightsizing: same as `krr` but emits YAML.
	bash lib/shell/krr.sh -f yaml

# Words after `make talosctl ...` (get, members, services, ...) are extra goals to Make; this no-op catch-all
# swallows them so they're passed to talosctl instead of erroring. Explicit targets above still take priority,
# so a mistyped real target quietly no-ops rather than erroring — the one cost of positional passthrough args.
%:
	@:
