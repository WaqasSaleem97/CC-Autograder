#!/usr/bin/env bash
set -u
submission_dir="$1"
total_marks="$2"

# Replace this example rubric with criteria appropriate for the selected lab.
score=0
feedback=()

if [[ -f "$submission_dir/main.py" ]]; then
  score=$((score + 3))
  feedback+=("main.py found: 3")
  if python3 -m py_compile "$submission_dir/main.py" >/dev/null 2>&1; then
    score=$((score + 7))
    feedback+=("valid Python syntax: 7")
  else
    feedback+=("invalid Python syntax: 0")
  fi
else
  feedback+=("main.py missing: 0")
fi

if (( score > total_marks )); then score="$total_marks"; fi
joined=$(IFS=';'; echo "${feedback[*]}")
node -e 'console.log(JSON.stringify({score:Number(process.argv[1]),feedback:process.argv[2]}))' "$score" "$joined"

