#!/usr/bin/env bash
# Refreshes the CrowdSec crawler allowlist now, instead of at the sidecar's next daily run. It runs the
# sidecar's own script in the sidecar, because `cscli allowlists` must run where the SQLite file is.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
CS_NS="crowdsec"
LAPI_DEPLOY="deploy/crowdsec-lapi"
SIDECAR="crawler-allowlist" # the container name in 03_crowdsec values.yaml

# ---- main ----

say "refreshing the crawler allowlist in ${CS_NS}/${LAPI_DEPLOY}"
require kubectl
use_kubeconfig
assert_api
if kubectl -n "$CS_NS" exec "$LAPI_DEPLOY" -c "$SIDECAR" -- bash /scripts/crawler-allowlist.sh once; then
  ok "every source loaded"
else
  bad "a source or a cscli step failed. See the lines above. The entries of a failed source stay as they were."
fi
summary
[ "$FAIL" -eq 0 ]
