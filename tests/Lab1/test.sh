#!/usr/bin/env bash

set -uo pipefail

SUBMISSION_DIR="${1:-}"
EXPECTED_OUTPUT="${2:-Cloud Computing Lab 1}"
SCORE=0
FEEDBACK=()

if [[ -z "$SUBMISSION_DIR" || ! -d "$SUBMISSION_DIR" ]]; then
  printf '{"score":0,"feedback":"Submission directory was not found."}\n'
  exit 0
fi

MAIN_FILE="$SUBMISSION_DIR/main.py"

# Criterion 1: required source file exists (2 marks).
if [[ -f "$MAIN_FILE" ]]; then
  SCORE=$((SCORE + 2))
  FEEDBACK+=("main.py found: 2/2")
else
  FEEDBACK+=("main.py missing: 0/2")
  printf '{"score":%d,"feedback":"%s"}\n' "$SCORE" "${FEEDBACK[*]}"
  exit 0
fi

# Criterion 2: Python syntax is valid (3 marks).
if python3 -m py_compile "$MAIN_FILE" >/dev/null 2>&1; then
  SCORE=$((SCORE + 3))
  FEEDBACK+=("valid Python syntax: 3/3")
else
  FEEDBACK+=("Python syntax error: 0/3")
  printf '{"score":%d,"feedback":"%s"}\n' "$SCORE" "${FEEDBACK[*]}"
  exit 0
fi

# Criterion 3: program finishes within 10 seconds and prints expected text (5 marks).
PROGRAM_OUTPUT="$(timeout 10s python3 "$MAIN_FILE" 2>/dev/null || true)"

if grep -Fq "$EXPECTED_OUTPUT" <<< "$PROGRAM_OUTPUT"; then
  SCORE=$((SCORE + 5))
  FEEDBACK+=("expected output found: 5/5")
else
  FEEDBACK+=("expected output not found: 0/5")
fi

FEEDBACK_TEXT="$(IFS='; '; echo "${FEEDBACK[*]}")"
printf '{"score":%d,"feedback":"%s"}\n' "$SCORE" "$FEEDBACK_TEXT"
