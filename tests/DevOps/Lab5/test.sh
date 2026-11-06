#!/usr/bin/env bash
set -euo pipefail

# DevOps_F26/Labs/Lab05: 37 required screenshots + Lab5_Solution.pdf.
# Usage: bash tests/DevOps/Lab5/test.sh SUBMISSION TOTAL_MARKS [GITHUB_USERNAME]
# Student code/builds/containers are never executed by this trusted grader.
test_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$test_directory/../evidence_grader.py" \
  "$test_directory/criteria.json" "$@"
