#!/usr/bin/env bash
# release-check says there is nothing to release when no commit follows the tag.
mx_release_fixture
mx_release_push
mx_run bin/maintainer-repo release-check
