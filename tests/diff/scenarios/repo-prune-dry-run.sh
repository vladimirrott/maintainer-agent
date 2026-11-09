#!/usr/bin/env bash
# prune --dry-run lists merged branches, local and remote, and deletes nothing.
mx_merge_env
mx_git_repo "$MX_REPO"
git init -q --bare -b main "$MX_WORK/origin.git"
git -C "$MX_REPO" remote add origin "$MX_WORK/origin.git"
mx_commit "$MX_REPO" first README.md one
mx_commit "$MX_REPO" second lib/a.sh two
git -C "$MX_REPO" branch feature-done
git -C "$MX_REPO" branch feature-open-pr
git -C "$MX_REPO" branch local-merged
git -C "$MX_REPO" push -q origin main feature-done feature-open-pr
git -C "$MX_REPO" checkout -q -b feature-wip
mx_commit "$MX_REPO" wip wip.txt wip
git -C "$MX_REPO" push -q origin feature-wip
git -C "$MX_REPO" checkout -q main
mx_stub gh <<'STUB'
case "$*" in
  *'pr list'*) printf 'feature-open-pr\nother-open\n' ;;
esac
STUB
mx_run bin/maintainer-repo prune --dry-run
