#!/usr/bin/env bash
# lease take writes the pull request's lease file with the epoch seconds of the take.
mx_merge_env
mx_run bin/maintainer lease take 5 --ttl 10m
