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
# yaml.safe_load instead of a regex. It comes from pip at CI's pin, not
# from apt: bookworm ships 6.0 and sysknife's CI installs 6.0.2, and a gate that
# parses a file with a different parser than CI can disagree with CI about it.
#
# yamllint is here for #471, which moved the issue-template lint behind
# scripts/lint-github-yaml.sh so composite actions are linted too. Without it
# tests/release/release-rehearsal.test.sh cannot run unmutated, no receipt is
# earnable, and the pull request waits on a human reading a refusal. The version
# is sysknife's CI pin (`pip install yamllint==1.38.0`); a different one would
# make this gate and CI disagree about the same file.
FROM docker.io/library/rust:1-bookworm
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      nodejs npm python3 python3-pip file git ca-certificates coreutils \
 && pip3 install --no-cache-dir --break-system-packages yamllint==1.38.0 PyYAML==6.0.2 \
 && rm -rf /var/lib/apt/lists/*
