#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "=== setup deps (non-fatal) ==="
[ -f package-lock.json ] && npm ci || true
[ -f requirements.txt ] && python3 -m pip install -r requirements.txt || true

echo "=== pre-validate input.json with schema.json ==="
if [ -f schema.json ] && [ -f input.json ]; then
  if [ -f validate_with_formats.js ] && command -v node >/dev/null 2>&1; then
    node validate_with_formats.js schema.json input.json || { echo "AJV pre-validate failed"; exit 1; }
  else
    npx ajv-cli validate -s schema.json -d input.json || { echo "AJV pre-validate failed"; exit 1; }
  fi

  python3 - <<'PY_PRE'
import json,sys
from jsonschema import validate,ValidationError
schema=json.load(open('schema.json'))
data=json.load(open('input.json'))
try:
  validate(instance=data,schema=schema)
  print("PY pre-validate: OK")
except ValidationError as e:
  print("PY pre-validate: FAIL"); print(e); sys.exit(1)
PY_PRE
fi

echo "=== ensure output.json exists ==="
if [ ! -f output.json ]; then
  echo "ERROR: output.json not found"
  exit 2
fi

echo "=== post-validate output.json against all *schema*.json ==="
FAIL=0
mkdir -p artifacts logs
TMPDIR="${TMPDIR:-$HOME/tmp}"\nmkdir -p "$TMPDIR"\nTMP_OUT="$(mktemp "$TMPDIR/validate_out.XXXXXX")"

for S in *schema*.json; do
  [ -f "$S" ] || continue
  echo "--- validating output.json against $S ---" | tee -a logs/validate.log

  if [ -f validate_with_formats.js ] && command -v node >/dev/null 2>&1; then
    if ! node validate_with_formats.js "$S" output.json 2>&1 | tee -a "logs/ajv_$(basename "$S").log"; then
      echo "AJV FAIL: $S" | tee -a logs/validate.log
      FAIL=1
    fi
  else
    if ! npx ajv-cli validate -s "$S" -d output.json 2>&1 | tee -a "logs/ajv_$(basename "$S").log"; then
      echo "AJV FAIL: $S" | tee -a logs/validate.log
      FAIL=1
    fi
  fi

  rm -f "$TMP_OUT"
  python3 - "$S" <<'PY_POST' >"$TMP_OUT" 2>&1
import json,sys
from jsonschema import validate,ValidationError
s = sys.argv[1]
schema = json.load(open(s))
data = json.load(open('output.json'))
try:
  validate(instance=data,schema=schema)
  print("PY OK for", s)
except ValidationError as e:
  print("PY FAIL for", s)
  print(e)
  sys.exit(2)
PY_POST

  cat "$TMP_OUT" | tee -a "logs/py_$(basename "$S").log"
  python_exit=${PIPESTATUS[0]:-$?}
  if [ "$python_exit" -ne 0 ]; then
    FAIL=1
  fi

done

rm -f "$TMP_OUT"

if [ "$FAIL" -ne 0 ]; then
  timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
  cp output.json "artifacts/output.failed.${timestamp}.json"
  echo "Validation failed. Artifacts saved to artifacts/" | tee -a logs/validate.log
  exit 3
fi

cp output.json artifacts/output.valid.json
echo "All validations passed." | tee -a logs/validate.log
exit 0
