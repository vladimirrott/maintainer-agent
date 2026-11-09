#!/usr/bin/env bash
# a run started from inside another run exits 78 and names the outer run.
mx_env MAINTAINER_IN_RUN magent/review
mx_run lib/run.sh sysknife review
