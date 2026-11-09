#!/usr/bin/env bash
# --quick on a healthy deployment: the same green checks, the slow probes skipped.
mx_deploy_fixture
mx_run bin/maintainer-doctor --quick
