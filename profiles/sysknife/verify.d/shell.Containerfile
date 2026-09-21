# Verify-suite image for the sysknife shell suite.
#
# tests/release/release-rehearsal.test.sh drives scripts/release_rehearsal.sh,
# which refuses to start without all five of:
#
#     for tool in cargo node npm sha256sum file; do
#
# docker.io/library/python:3.12 carries sha256sum and file and neither cargo,
# node nor npm, so the gate could not run that test unmutated and refused to
# write a receipt for every pull request touching it (#443, #435, #446).
#
# PyYAML is here for #446, which parses workflow action references with
# yaml.safe_load instead of a regex.
FROM docker.io/library/rust:1-bookworm
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      nodejs npm python3 python3-yaml file git ca-certificates coreutils \
 && rm -rf /var/lib/apt/lists/*
