#!/usr/bin/env bash
# a pull request argument that is not a positive integer never becomes a path.
mx_merge_env
mx_run bin/maintainer-merge merge '1;rm -rf x'
