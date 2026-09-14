#!/usr/bin/env bash
# Run a command, retrying with exponential backoff until it succeeds.
#
# Chart dependencies download from GitHub release assets, which occasionally
# answer 504 from Actions runners for minutes at a time; one blip used to fail
# the whole release. Defaults wait 15+30+60+120+240s (~8 min) across 6 attempts.
#
# Usage: scripts/retry.sh <command> [args...]
# Env:   RETRY_ATTEMPTS (default 6), RETRY_DELAY (initial delay in seconds, default 15)
set -uo pipefail

attempts=${RETRY_ATTEMPTS:-6}
delay=${RETRY_DELAY:-15}

for ((i = 1; ; i++)); do
  "$@" && exit 0
  if ((i >= attempts)); then
    echo "retry.sh: giving up after $attempts attempts: $*" >&2
    exit 1
  fi
  echo "retry.sh: attempt $i/$attempts failed, retrying in ${delay}s: $*" >&2
  sleep "$delay"
  delay=$((delay * 2))
done
