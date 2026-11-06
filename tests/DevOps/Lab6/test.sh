#!/usr/bin/env bash
set -euo pipefail

# DevOps_F26/Labs/Lab06: 28 required screenshots + Lab6_Solution.pdf.
# Usage: bash tests/DevOps/Lab6/test.sh SUBMISSION TOTAL_MARKS [GITHUB_USERNAME]
# No live API requests or destructive Nexus cleanup/compaction tasks are run.
test_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$test_directory/../evidence_grader.py" \
  "$test_directory/criteria.json" "$@"
