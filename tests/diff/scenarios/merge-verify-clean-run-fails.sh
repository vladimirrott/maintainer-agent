#!/usr/bin/env bash
# verify extracts the pull request into a random scratch directory, mounts it into the
# container and stops with "does not pass unmutated" when the clean run fails. The
# scratch name is random, and it appears in the podman argv.
mx_merge_env
mx_env MAINTAINER_PROFILE magent
mx_git_repo "$MX_REPO"
mx_commit "$MX_REPO" "base" README.md "base"
mx_commit "$MX_REPO" "docs" docs/a.md "words"
mx_pr_origin 5
head="$(git -C "$MX_REPO" rev-parse HEAD)"
mx_stub gh <<'STUB'
case "$*" in
  *'auth switch'*) exit 0 ;;
  *'api user'*) echo testuser ;;
  *'pr view 5'*) echo docs/a.md ;;
esac
STUB
mx_stub podman 'echo "check_claims: boom"; exit 1'
mx_run bin/maintainer-merge verify 5 "$head" check_claims 's/words/other/' docs
