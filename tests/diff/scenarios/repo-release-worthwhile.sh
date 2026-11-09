#!/usr/bin/env bash
# release-check: production code changed, no Security heading and no removed-capability wording.
mx_release_fixture
mx_commit "$MX_REPO" "feat(bin): add a flag" bin/tool "one more flag" CHANGELOG.md "# Changelog

## [Unreleased]

### Added
- A flag.

## [0.1.0] - 2026-01-01
### Added
- first release"
mx_release_push
mx_run bin/maintainer-repo release-check
