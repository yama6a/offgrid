#!/usr/bin/env bash
# Merges the public repo's main into the current branch. It merges and never rebases, because the branch is
# pushed to origin. A rebase rewrites published history and makes every sync resolve old conflicts again.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
REMOTE="upstream" # git remote of the public repo
BASE="main"       # branch to merge from

# ---- state ----
SLUG=""    # owner/repo of the public repo, for the messages
HERE=""    # the current branch, which receives the merge
INCOMING=0 # number of commits to merge

# ---- functions ----

check_prerequisites() {
  require git
  git rev-parse --git-dir > /dev/null 2>&1 || die "not a git repo"
  git diff --quiet && git diff --cached --quiet \
    || die "the working tree has changes. Commit or stash them first, because a merge needs a clean tree."
  git remote get-url "$REMOTE" > /dev/null 2>&1 \
    || die "no '${REMOTE}' remote. Add it: git remote add ${REMOTE} git@github.com:<owner>/<public repo>.git"
  SLUG="$(git remote get-url "$REMOTE" | sed -E 's#\.git$##; s#^.*[:/]([^/]+/[^/]+)$#\1#')"
  HERE="$(git rev-parse --abbrev-ref HEAD)"
  [ "$HERE" != HEAD ] || die "detached HEAD. Check out a branch first."
}

fetch_upstream() {
  say "fetching ${SLUG}"
  git fetch --quiet "$REMOTE" || die "cannot reach ${REMOTE} (${SLUG})"
  INCOMING="$(git rev-list --count "HEAD..${REMOTE}/${BASE}")"
  [ "$INCOMING" -gt 0 ] || {
    ok "${HERE} already has everything from ${SLUG} ${BASE}"
    exit 0
  }
}

show_incoming() {
  say "${INCOMING} commit(s) to merge into ${HERE}"
  git --no-pager log --oneline --no-decorate "HEAD..${REMOTE}/${BASE}" | sed 's/^/  /'
  echo
  git --no-pager diff --stat "HEAD...${REMOTE}/${BASE}"
  confirm "merge these into ${HERE}?" || die "aborted, nothing changed"
}

merge_upstream() {
  git merge --no-edit "${REMOTE}/${BASE}" && {
    ok "merged into ${HERE}"
    return 0
  }
  cat << EOF

The merge has conflicts. Resolve them yourself. "Ours" is ${HERE}, and "theirs" is ${SLUG} ${BASE}.
  git status
  <fix the files> && git add -A && git commit
To cancel the whole merge:
  git merge --abort
EOF
  exit 1
}

print_result() {
  cat << EOF

When the result is right, push it to the private remote:
  git push origin ${HERE}
EOF
}

# ---- main ----

check_prerequisites
fetch_upstream
show_incoming
merge_upstream
print_result
