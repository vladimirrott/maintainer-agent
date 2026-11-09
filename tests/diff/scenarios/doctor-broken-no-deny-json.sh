#!/usr/bin/env bash
# one broken check: the profile lost its deny.json, so doctor fails and exits 1.
mx_deploy_fixture
rm "$MX_HOME/.local/share/maintainer/profiles/p/deny.json"
mx_run bin/maintainer-doctor --quick
