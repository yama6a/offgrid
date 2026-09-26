#!/usr/bin/env bash
# Checks that every running image has a manifest for every node architecture in the cluster.
# The scheduler ignores image architecture, so an arm64-only pod on an amd64 node fails with `exec format error`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat << EOF
check_multiarch.sh                      (or: make check-multiarch [ARCH=amd64])
  ARCH="amd64 arm64"   require these architectures instead of the ones the cluster runs now

Reads the live pods, not values.yaml. Most images come from upstream charts and never appear in this repo.
Run it before a node of a new architecture takes workloads, and after a chart bump.

SKIP_IMAGES at the top of this script exempts images that are single-arch on purpose.
A stale entry hides a broken image. Remove the entry when the pod that needed it goes.
EOF
}

# ---- knobs ----
ERR_FILE="/tmp/.ma_err" # stderr of docker manifest inspect, to tell a failed read from a missing platform

# Images that are single-arch on purpose. Add an entry only after the chart pins the pod to its architecture.
# A skipped image without that pin still crashloops, only later, at deploy.
SKIP_IMAGES=(
  "intel/intel-gpu-plugin" # upstream is amd64-only. The chart sets nodeAffinity on extensions.talos.dev/i915.
)

# ---- state ----
ARCHES=() # set by resolve_required_arches
IMAGES="" # set by collect_pod_images
UNREAD=0  # bumped by check_image
HAVE=""   # set by read_image_arches: the architectures found, empty if the manifest could not be read
READ_ERR=""

# ---- functions ----

check_prerequisites() {
  require docker kubectl
  docker info > /dev/null 2>&1 || die "docker does not respond. Start Rancher Desktop or Docker Desktop."
  use_kubeconfig
  assert_api
}

# The kubelet sets kubernetes.io/arch itself, so the live nodes are the reliable source.
# ARCH checks an architecture before a node of it exists.
resolve_required_arches() {
  if [ -n "${ARCH:-}" ]; then
    read -ra ARCHES <<< "$ARCH"
    say "requiring: ${ARCHES[*]}  (from ARCH=)"
    return 0
  fi
  read -ra ARCHES <<< "$(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.labels.kubernetes\.io/arch}{"\n"}{end}' 2> /dev/null | sort -u | tr '\n' ' ')"
  [ "${#ARCHES[@]}" -gt 0 ] || die "could not read kubernetes.io/arch from any node"
  say "requiring: ${ARCHES[*]}  (every architecture in the cluster)"
}

# Without auth, `manifest inspect` reports a private image as "unauthorized", which looks like a missing platform.
# An empty token skips the login, which is fine when every image is public.
login_to_ghcr() {
  [ -n "${GITHUB_GHCR_PULL_TOKEN_SECRET}" ] || return 0
  printf '%s' "$GITHUB_GHCR_PULL_TOKEN_SECRET" \
    | docker login "$GHCR_SERVER" -u "$GHCR_USER" --password-stdin > /dev/null 2>&1 \
    && ok "logged in to ${GHCR_SERVER}" || warn "could not log in to ${GHCR_SERVER}. Private images can read as missing."
  return 0
}

# Includes initContainers. An arm64-only init container fails the pod the same way, and is easy to miss.
collect_pod_images() {
  IMAGES="$(kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
    2> /dev/null | grep . | sort -u)"
  [ -n "$IMAGES" ] || die "found no pod images. Check that this is the right cluster."
  say "$(printf '%s\n' "$IMAGES" | grep -c .) distinct images"
}

# --verbose returns a list with Descriptor.platform for an index and a single image alike.
# So a digest that pins one platform, not the index, fails here too. The os filter drops attestation entries.
# Retries, because a transient failure returns nothing and looks like a missing platform.
# Stops at a rate limit: Docker Hub's window is hours, and each retry cycle sleeps 43s for nothing.
read_image_arches() {
  local img="$1" s raw
  HAVE=""
  READ_ERR=""
  for s in 0 3 10 30; do
    [ "$s" -gt 0 ] && sleep "$s"
    raw="$(docker manifest inspect --verbose "$img" 2> "$ERR_FILE")"
    READ_ERR="$(cat "$ERR_FILE")"
    HAVE="$(printf '%s' "$raw" | yq -r '[.[].Descriptor.platform | select(.os == "linux") | .architecture] | unique | join(" ")' 2> /dev/null)"
    [ -n "$HAVE" ] && break
    grep -qiE 'rate limit|toomanyrequests' <<< "$READ_ERR" && break
  done
}

# A failed read is a local problem, such as a rate limit or no login. The cluster already pulls this image.
# So it warns and counts, but does not fail the run.
check_image() {
  local img="$1" missing="" a skip
  for skip in "${SKIP_IMAGES[@]}"; do
    case "$img" in "${skip}"*)
      say "${img}: skipped, single-arch on purpose"
      return 0
      ;;
    esac
  done
  read_image_arches "$img"
  if [ -z "$HAVE" ]; then
    UNREAD=$((UNREAD + 1))
    warn "${img}: could not read its manifest, not checked (${READ_ERR##*: })"
    return 0
  fi
  for a in "${ARCHES[@]}"; do
    case " ${HAVE} " in *" ${a} "*) ;; *) missing="${missing} ${a}" ;; esac
  done
  if [ -z "${missing// /}" ]; then
    ok "${img}  [${HAVE}]"
  else
    bad "${img}: no ${missing# } manifest (has: ${HAVE})"
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
  echo "Fix a failing image with a multi-arch rebuild, or with a nodeAffinity on kubernetes.io/arch in its chart."
  echo "The nodeAffinity stops the scheduler from placing it on nodes it cannot run on."
  [ "$UNREAD" -gt 0 ] && warn "${UNREAD} image(s) could not be read and were not checked. The usual cause is the Docker Hub rate limit. Run \`docker login\` and run this again."
  return 0
}

# ---- main ----

case "${1:-}" in -h | --help)
  usage
  exit 0
  ;;
esac

check_prerequisites
resolve_required_arches
login_to_ghcr
collect_pod_images
check_every_image
print_result

summary || exit 1
