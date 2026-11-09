#!/usr/bin/env bash
# release-check reads the tag, the commits since it and the Unreleased changelog section.
mx_merge_env
mx_env PROD_GLOBS 'bin/* lib/*'
mx_env SHIPPED_GLOBS 'bin/*'
mx_git_repo "$MX_REPO"
git init -q --bare -b main "$MX_WORK/origin.git"
git -C "$MX_REPO" remote add origin "$MX_WORK/origin.git"
mx_commit "$MX_REPO" "release 0.1.0" CHANGELOG.md "# Changelog

## [Unreleased]

## [0.1.0] - 2026-01-01
### Added
- first release"
git -C "$MX_REPO" tag v0.1.0
mx_commit "$MX_REPO" "fix(bin): refuse a forged receipt" bin/tool "fixed"
mx_commit "$MX_REPO" "docs: wording" docs/a.md "words" CHANGELOG.md "# Changelog

## [Unreleased]

### Security
- The gate refuses a forged receipt.

## [0.1.0] - 2026-01-01
### Added
- first release"
git -C "$MX_REPO" push -q origin main v0.1.0
mx_run bin/maintainer-repo release-check
