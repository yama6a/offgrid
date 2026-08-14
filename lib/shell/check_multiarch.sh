#!/usr/bin/env bash
# Checks every image running in the cluster has a manifest for every architecture in the cluster. The scheduler
# does not look at an image's architecture: it will place an arm64-only pod on an amd64 node and let it
# CrashLoopBackOff with `exec format error`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
check_multiarch.sh                      (or: make check-multiarch [ARCH=amd64])
  ARCH="amd64 arm64"   require these architectures instead of the ones the cluster currently runs

Reads the LIVE pods, not values.yaml: most images come from upstream charts and never appear in this repo.
Run it before a node of a new architecture takes workloads, and after a chart bump.
EOF
}

# ---- knobs ----
ERR_FILE="/tmp/.ma_err"   # docker manifest inspect's stderr, so a failed read can be told apart from a miss

# ---- state ----
ARCHES=()    # set by resolve_required_arches
IMAGES=""    # set by collect_pod_images
UNREAD=0     # bumped by check_image
HAVE=""      # set by read_image_arches: the architectures found, empty if the manifest could not be read
READ_ERR=""

# ---- functions ----

check_prerequisites() {
  require docker kubectl
  docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
  use_kubeconfig
  assert_api
}

# The kubelet sets kubernetes.io/arch itself, so the live nodes are the honest source; ARCH is for checking
# before such a node exists.
resolve_required_arches() {
  if [ -n "${ARCH:-}" ]; then
    read -ra ARCHES <<< "$ARCH"
    say "requiring: ${ARCHES[*]}  (from ARCH=)"
    return 0
  fi
  read -ra ARCHES <<< "$(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.labels.kubernetes\.io/arch}{"\n"}{end}' 2>/dev/null | sort -u | tr '\n' ' ')"
  [ "${#ARCHES[@]}" -gt 0 ] || die "could not read kubernetes.io/arch from any node"
  say "requiring: ${ARCHES[*]}  (every architecture in the cluster)"
}

# A private ref needs auth or `manifest inspect` reports "unauthorized", which cannot be told apart from a
# genuinely missing platform. Skipped when the token is empty, fine if every image is public.
login_to_ghcr() {
  [ -n "${GITHUB_GHCR_PULL_TOKEN_SECRET}" ] || return 0
  printf '%s' "$GITHUB_GHCR_PULL_TOKEN_SECRET" \
    | docker login "$GHCR_SERVER" -u "$GHCR_USER" --password-stdin >/dev/null 2>&1 \
    && ok "logged in to ${GHCR_SERVER}" || warn "could not log in to ${GHCR_SERVER}; private images may read as missing"
  return 0
}

# initContainers too: an arm64-only init container fails just as hard as an arm64-only app, and is easy to miss.
collect_pod_images() {
  IMAGES="$(kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
            2>/dev/null | grep . | sort -u)"
  [ -n "$IMAGES" ] || die "no pod images found, is this the right cluster?"
  say "$(printf '%s\n' "$IMAGES" | grep -c .) distinct images"
}

# --verbose so the shape is the same either way: always a list of entries with a Descriptor.platform, whether
# the ref is a manifest index or a single image. So a digest pinning ONE platform rather than the index fails
# here too, which is the case reading values.yaml cannot catch. The os filter drops attestation entries, which
# carry architecture "unknown".
# Backed off, because a transient read returns nothing and looks identical to a missing platform. A RATE LIMIT
# is not transient though (Docker Hub's window is hours), so stop retrying the moment one appears: otherwise
# every unauthenticated image costs 43s of sleeping to learn what the first attempt already said.
read_image_arches() {
  local img="$1" s raw
  HAVE=""; READ_ERR=""
  for s in 0 3 10 30; do
    [ "$s" -gt 0 ] && sleep "$s"
    raw="$(docker manifest inspect --verbose "$img" 2>"$ERR_FILE")"; READ_ERR="$(cat "$ERR_FILE")"
    HAVE="$(printf '%s' "$raw" | yq -r '[.[].Descriptor.platform | select(.os == "linux") | .architecture] | unique | join(" ")' 2>/dev/null)"
    [ -n "$HAVE" ] && break
    grep -qiE 'rate limit|toomanyrequests' <<< "$READ_ERR" && break
  done
}

# A read we could not make is NOT evidence of a missing platform, and counting it as one sends you chasing a
# problem that is not there: the pod is running this image, so the cluster can pull it, and a failure here is
# local (rate limit, no login). Reported separately so it is visible without failing the run.
check_image() {
  local img="$1" missing="" a
  read_image_arches "$img"
  if [ -z "$HAVE" ]; then
    UNREAD=$((UNREAD+1))
    warn "${img}: could not read its manifest, NOT checked (${READ_ERR##*: })"
    return 0
  fi
  for a in "${ARCHES[@]}"; do
    printf '%s\n' $HAVE | grep -qx "$a" || missing="${missing} ${a}"
  done
  if [ -z "${missing// }" ]; then ok "${img}  [${HAVE}]"
  else                           bad "${img}: no ${missing# } manifest (has: ${HAVE})"
  fi
}

check_every_image() {
  local img
  while read -r img; do
    [ -n "$img" ] || continue
    check_image "$img"
  done <<< "$IMAGES"
  rm -f "$ERR_FILE"
}

print_result() {
  echo
  echo "A failing image needs either a multi-arch rebuild, or a nodeAffinity on kubernetes.io/arch in its chart"
  echo "so the scheduler stops offering it nodes it cannot run on."
  [ "$UNREAD" -gt 0 ] && warn "${UNREAD} image(s) could not be read and were NOT checked. Usually Docker Hub rate limiting: \`docker login\` and re-run."
  return 0
}

# ---- main ----

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

check_prerequisites
resolve_required_arches
login_to_ghcr
collect_pod_images
check_every_image
print_result

summary || exit 1
