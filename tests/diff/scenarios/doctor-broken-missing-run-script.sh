#!/usr/bin/env bash
# --quick when the deployed run.sh is gone: doctor reports the missing file and exits 1.
mx_deploy_fixture
rm "$MX_HOME/.local/share/maintainer/run.sh"
mx_run bin/maintainer-doctor --quick
