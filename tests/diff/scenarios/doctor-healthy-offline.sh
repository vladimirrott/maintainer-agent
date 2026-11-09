#!/usr/bin/env bash
# a deployed profile on a healthy machine: every check green, podman stubbed, no network.
mx_deploy_fixture
mx_run bin/maintainer-doctor
