#!/usr/bin/env bash
# Stable tags use the same CLT qualification and hosted sole publisher.
set -euo pipefail
if [ "$#" != 2 ] || ! [[ "$1" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: $0 vMAJOR.MINOR.PATCH CANDIDATE_RUN_ID" >&2
  exit 1
fi
exec bash "$(dirname "$0")/release.sh" "$@"
