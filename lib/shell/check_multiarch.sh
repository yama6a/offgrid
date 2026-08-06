#!/usr/bin/env bash
# Checks every image running in the cluster has a manifest for every architecture in the cluster.
#
# The scheduler does not look at an image's architecture. It will place an arm64-only pod on an amd64 node and
# let it CrashLoopBackOff with `exec format error`, so on a mixed-architecture cluster this is the gate before
# a new node takes workloads. Worth re-running after a chart bump too.
#
# Reads the LIVE pods, not values.yaml: most images come from upstream charts and never appear in this repo.
# Reads the live nodes for the architectures, so it checks what the cluster actually is; ARCH= overrides that
# to check ahead of adding a node of an architecture no node has yet.
#
# Usage:
#   bash check_multiarch.sh              # require every arch the cluster currently runs
#   ARCH="amd64 arm64" bash ...          # require these instead
#   make check-multiarch [ARCH=amd64]
#
# Requires: docker (for `docker manifest inspect`) + kubectl
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require docker kubectl
docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
use_kubeconfig
assert_api

# The architectures to require. The kubelet sets kubernetes.io/arch itself, so the live nodes are the honest
# source; ARCH is for checking before such a node exists.
if [ -n "${ARCH:-}" ]; then
  read -ra ARCHES <<< "$ARCH"
  say "requiring: ${ARCHES[*]}  (from ARCH=)"
else
  read -ra ARCHES <<< "$(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.labels.kubernetes\.io/arch}{"\n"}{end}' 2>/dev/null | sort -u | tr '\n' ' ')"
  [ "${#ARCHES[@]}" -gt 0 ] || die "could not read kubernetes.io/arch from any node"
  say "requiring: ${ARCHES[*]}  (every architecture in the cluster)"
fi

# A private ref needs auth or `manifest inspect` reports "unauthorized" and we cannot tell that apart from a
# genuinely missing platform. Skipped when the token is empty, which is fine if every image is public.
if [ -n "${GITHUB_GHCR_PULL_TOKEN_SECRET}" ]; then
  printf '%s' "$GITHUB_GHCR_PULL_TOKEN_SECRET" \
    | docker login "$GHCR_SERVER" -u "$GHCR_USER" --password-stdin >/dev/null 2>&1 \
    && ok "logged in to ${GHCR_SERVER}" || warn "could not log in to ${GHCR_SERVER}; private images may read as missing"
fi

# initContainers too: an arm64-only init container fails just as hard as an arm64-only app, and is easy to miss.
IMAGES="$(kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
          2>/dev/null | grep . | sort -u)"
[ -n "$IMAGES" ] || die "no pod images found, is this the right cluster?"
say "$(printf '%s\n' "$IMAGES" | grep -c .) distinct images"
UNREAD=0

while read -r img; do
  [ -n "$img" ] || continue
  # --verbose so the shape is the same either way: always a list of entries with a Descriptor.platform, whether
  # the ref is a manifest index or a single image. So a digest pinning ONE platform rather than the index fails
  # here too, which is the case reading values.yaml cannot catch. The os filter drops attestation entries,
  # which carry architecture "unknown".
  # Backed off, because a transient read returns nothing and looks identical to a missing platform. A RATE LIMIT
  # is not transient though (Docker Hub's window is hours), so stop retrying the moment we see one: otherwise
  # every unauthenticated image costs 43s of sleeping to learn what the first attempt already said.
  have=""; err=""
  for s in 0 3 10 30; do
    [ "$s" -gt 0 ] && sleep "$s"
    raw="$(docker manifest inspect --verbose "$img" 2>/tmp/.ma_err)"; err="$(cat /tmp/.ma_err)"
    have="$(printf '%s' "$raw" | yq -r '[.[].Descriptor.platform | select(.os == "linux") | .architecture] | unique | join(" ")' 2>/dev/null)"
    [ -n "$have" ] && break
    grep -qiE 'rate limit|toomanyrequests' <<< "$err" && break
  done
  # A read we could not make is NOT evidence of a missing platform, and counting it as one sends you chasing a
  # problem that is not there. The pod is running this image, so the cluster can pull it; a failure here is
  # local (rate limit, no login). Reported separately so it is visible without failing the run.
  if [ -z "$have" ]; then
    UNREAD=$((UNREAD+1))
    warn "${img}: could not read its manifest, NOT checked (${err##*: })"
    continue
  fi
  missing=""
  for a in "${ARCHES[@]}"; do
    printf '%s\n' $have | grep -qx "$a" || missing="${missing} ${a}"
  done
  if [ -z "${missing// }" ]; then ok "${img}  [${have}]"
  else                           bad "${img}: no ${missing# } manifest (has: ${have})"
  fi
done <<< "$IMAGES"

rm -f /tmp/.ma_err
echo
echo "A failing image needs either a multi-arch rebuild, or a nodeAffinity on kubernetes.io/arch in its chart"
echo "so the scheduler stops offering it nodes it cannot run on."
[ "$UNREAD" -gt 0 ] && warn "${UNREAD} image(s) could not be read and were NOT checked. Usually Docker Hub rate limiting: \`docker login\` and re-run."
summary || exit 1
