#!/usr/bin/env bash
# Opens a PR on the public repo from commits made here. It cherry-picks them onto a branch off upstream/main.
# Only the commits you name leave this repo, and it shows the diff before it pushes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat << EOF
upstream_pr.sh [<branch> [<sha>...]]      (or: make upstream-pr)
  branch   name of the new branch on the public repo
  sha      commits to cherry-pick, oldest first
The script asks for any argument you leave out. Nothing is pushed before you confirm the diff.
EOF
}

# ---- knobs ----
REMOTE="upstream" # git remote of the public repo
BASE="main"       # branch the PR targets

# ---- state ----
BRANCH="" # new branch on the public repo
SHAS=()   # commits to cherry-pick
SLUG=""   # owner/repo of the public repo. Without it, gh picks origin, which is the private repo.
BACK=""   # the starting branch. Every exit path returns to it.

# ---- functions ----

check_prerequisites() {
  require git gh
  git rev-parse --git-dir > /dev/null 2>&1 || die "not a git repo"
  git diff --quiet && git diff --cached --quiet \
    || die "the working tree has changes. Commit or stash them first, because a cherry-pick needs a clean tree."
  git remote get-url "$REMOTE" > /dev/null 2>&1 \
    || die "no '${REMOTE}' remote. Add it: git remote add ${REMOTE} git@github.com:<owner>/<public repo>.git"
  SLUG="$(git remote get-url "$REMOTE" | sed -E 's#\.git$##; s#^.*[:/]([^/]+/[^/]+)$#\1#')"
  BACK="$(git rev-parse --abbrev-ref HEAD)"
  git fetch --quiet "$REMOTE" || die "cannot reach ${REMOTE} (${SLUG})"
}

read_inputs() {
  BRANCH="${1:-}"
  [ "$#" -gt 0 ] && shift
  SHAS=("$@")
  [ -n "$BRANCH" ] || read -rp "branch name: " BRANCH
  [ -n "$BRANCH" ] || die "no branch name"
  if [ "${#SHAS[@]}" -eq 0 ]; then
    local line
    read -rp "SHAs, space separated, oldest first: " line
    read -ra SHAS <<< "$line"
  fi
  [ "${#SHAS[@]}" -gt 0 ] || die "no commits given"
  local s
  for s in "${SHAS[@]}"; do
    git rev-parse --verify --quiet "${s}^{commit}" > /dev/null || die "not a commit in this repo: ${s}"
  done
  ! git show-ref --verify --quiet "refs/heads/${BRANCH}" || die "branch ${BRANCH} already exists locally"
  ! git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" > /dev/null 2>&1 \
    || die "branch ${BRANCH} already exists on ${SLUG}"
}

abort() {
  git cherry-pick --abort 2> /dev/null
  git checkout --quiet "$BACK" && git branch -D "$BRANCH" > /dev/null
  die "$1"
}

cherry_pick_onto_upstream() {
  say "branching ${BRANCH} off ${REMOTE}/${BASE}, cherry-picking ${#SHAS[@]} commit(s)"
  git checkout --quiet -b "$BRANCH" "${REMOTE}/${BASE}" || die "could not branch off ${REMOTE}/${BASE}"
  git cherry-pick "${SHAS[@]}" \
    || abort "the cherry-pick stopped on a conflict, or a commit is already upstream. Back on ${BACK}, ${BRANCH} deleted."
  ok "$(git rev-list --count "${REMOTE}/${BASE}"..HEAD) commit(s) on ${BRANCH}"
}

confirm_publication() {
  say "what this adds to ${SLUG}"
  git --no-pager diff --stat "${REMOTE}/${BASE}...HEAD"
  warn "read the file list. Everything in it is public once pushed, and it stays in the history."
  # Not plain confirm, because an ASSUME_YES left over from another command must never publish anything.
  confirm_word_always PUBLISH "this cannot be undone:" || abort "aborted, nothing pushed"
}

push_and_open_pr() {
  git push --quiet -u "$REMOTE" "$BRANCH" || abort "push to ${SLUG} failed"
  gh pr create --repo "$SLUG" --base "$BASE" --head "$BRANCH" --fill \
    || warn "${BRANCH} is pushed to ${SLUG}, but gh could not open the PR. Open it in the browser."
  git checkout --quiet "$BACK" || warn "could not switch back to ${BACK}, you are on ${BRANCH}"
}

print_result() {
  cat << EOF

After the PR merges, merge it back into this repo:
  git fetch ${REMOTE} && git merge ${REMOTE}/${BASE}
The cherry-pick made new commits. Until you merge back, ${BACK} holds each change twice.
EOF
}

# ---- main ----

case "${1:-}" in -h | --help)
  usage
  exit 0
  ;;
esac

check_prerequisites
read_inputs "$@"
cherry_pick_onto_upstream
confirm_publication
push_and_open_pr
print_result
