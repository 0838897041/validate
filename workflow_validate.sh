#!/data/data/com.termux/files/usr/bin/bash
# workflow_validate.sh
# Production-ready end-to-end JSON validate workflow (AJV + Python jsonschema)
# Features: venv detection, artifact logging, atomic writes, configurable AJV strictness,
#           processor plugin (py/js), idempotent example creation, clear exit codes.
set -euo pipefail

# ---------------------------
# Configuration (override via env or CLI)
# ---------------------------
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
VENV_DIR="${VENV_DIR:-$PROJECT_DIR/.venv}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$PROJECT_DIR/artifacts}"
SCHEMA="${SCHEMA:-$PROJECT_DIR/schema.json}"
INPUT="${INPUT:-$PROJECT_DIR/input.json}"
OUTPUT="${OUTPUT:-$PROJECT_DIR/output.json}"
OUTPUT_SCHEMA="${OUTPUT_SCHEMA:-$PROJECT_DIR/output_schema.json}"
PROCESSOR="${PROCESSOR:-}"            # optional: path to processor script (python or node)
AJV_STRICT="${AJV_STRICT:-false}"    # default: non-strict AJV (avoid unknown format errors)
PYTHON_CMD="${PYTHON_CMD:-python}"
LOGFILE="$ARTIFACT_DIR/validate.log"

# ---------------------------
# Helpers
# ---------------------------
mkdir -p "$ARTIFACT_DIR"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOGFILE"; }

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]
Options:
  --schema PATH         input schema (default: $SCHEMA)
  --input PATH          input json (default: $INPUT)
  --output PATH         output json (default: $OUTPUT)
  --output-schema PATH  output schema (default: $OUTPUT_SCHEMA)
  --processor PATH      processor script to produce output (python or node)
  --no-ajv-nonstrict    run ajv in strict mode (default: non-strict)
  --help                show this help
Examples:
  $(basename "$0") --schema in_schema.json --input in.json --processor process.py
USAGE
  exit 2
}

# ---------------------------
# CLI arg parsing (simple)
# ---------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --schema) SCHEMA="$2"; shift 2;;
    --input) INPUT="$2"; shift 2;;
    --output) OUTPUT="$2"; shift 2;;
    --output-schema) OUTPUT_SCHEMA="$2"; shift 2;;
    --processor) PROCESSOR="$2"; shift 2;;
    --no-ajv-nonstrict) AJV_STRICT=true; shift;;
    --help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

# ---------------------------
# Environment: activate venv if present
# ---------------------------
if [ -f "$VENV_DIR/bin/activate" ]; then
  # shellcheck disable=SC1090
  . "$VENV_DIR/bin/activate"
  PYTHON_CMD="${VENV_DIR}/bin/python"
  log "Activated venv: $VENV_DIR"
else
  log "No venv found at $VENV_DIR; using system python ($PYTHON_CMD)"
fi

# ---------------------------
# Utility functions
# ---------------------------
# run AJV (global ajv or npx fallback). Returns AJV exit code.
run_ajv() {
  local schema="$1" data="$2"
  local extra="--errors=text"
  if [ "$AJV_STRICT" = "false" ]; then
    extra="$extra --strict=false"
  fi
  if command -v ajv >/dev/null 2>&1; then
    ajv validate -s "$schema" -d "$data" $extra
  else
    npx --yes ajv-cli validate -s "$schema" -d "$data" $extra
  fi
}

# run Python jsonschema validate (prints details). Returns exit code.
run_python_validate() {
  local schema="$1" data="$2"
  "$PYTHON_CMD" - <<PYCODE
import json,sys
from jsonschema import validate, ValidationError, SchemaError
def load(p):
    with open(p,'r',encoding='utf-8') as f:
        return json.load(f)
try:
    schema = load("$schema")
    data = load("$data")
except Exception as e:
    print("PY ERROR loading files:", e); sys.exit(2)
try:
    validate(instance=data, schema=schema)
    print("PYTHON VALID"); sys.exit(0)
except ValidationError as e:
    print("PYTHON INVALID")
    print("Message:", e.message)
    print("Path:", list(e.path))
    print("Validator:", e.validator)
    print("Schema path:", list(e.schema_path))
    sys.exit(1)
except SchemaError as e:
    print("PYTHON SCHEMA ERROR:", e); sys.exit(3)
PYCODE
}

# atomic write helper: write stdin to tmp then mv
atomic_write() {
  local dest="$1"
  local tmp
  tmp="$(mktemp -p "$(dirname "$dest")" tmp.XXXXXX)" || return 1
  cat > "$tmp"
  mv "$tmp" "$dest"
}

# ensure example files exist (idempotent)
ensure_example_files() {
  if [ ! -f "$SCHEMA" ]; then
    cat > "$SCHEMA" <<'JSON'
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "id": {"type": "integer"},
    "name": {"type": "string"}
  },
  "required": ["id","name"]
}
JSON
    log "Created example schema: $SCHEMA"
  fi

  if [ ! -f "$INPUT" ]; then
    cat > "$INPUT" <<'JSON'
{
  "id": 1,
  "name": "example"
}
JSON
    log "Created example input: $INPUT"
  fi

  if [ ! -f "$OUTPUT_SCHEMA" ]; then
    cat > "$OUTPUT_SCHEMA" <<'JSON'
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "result": {"type": "object"},
    "sourceId": {"type": "integer"},
    "processedAt": {"type": "string"}
  },
  "required": ["result","sourceId"],
  "additionalProperties": true
}
JSON
    log "Created example output schema (forward-compatible): $OUTPUT_SCHEMA"
  fi
}

# default processor: Python wrapper that writes atomically
default_process() {
  local tmp
  tmp="$(mktemp -p "$(dirname "$OUTPUT")" tmp.out.XXXXXX)" || { log "Failed to create tmp file"; return 30; }
  "$PYTHON_CMD" - <<PYPY > "$tmp"
import json,time,sys
infile="$INPUT"
try:
    with open(infile,'r',encoding='utf-8') as f:
        data=json.load(f)
except Exception as e:
    print("PROCESS ERROR reading input:", e); sys.exit(2)
out={"result": data, "sourceId": data.get("id",0), "processedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
with open("$tmp",'w',encoding='utf-8') as f:
    json.dump(out,f,ensure_ascii=False,indent=2)
print("WROTE", "$tmp")
PYPY
  mv "$tmp" "$OUTPUT"
  log "Processed $INPUT -> $OUTPUT (atomic)"
}

# run processor (user-provided or default)
run_processor() {
  if [ -n "$PROCESSOR" ]; then
    if [ ! -f "$PROCESSOR" ]; then
      log "Processor not found: $PROCESSOR"; return 31
    fi
    case "$PROCESSOR" in
      *.py) "$PYTHON_CMD" "$PROCESSOR" "$INPUT" "$OUTPUT";;
      *.js) node "$PROCESSOR" "$INPUT" "$OUTPUT";;
      *) log "Unknown processor type: $PROCESSOR; using default"; default_process;;
    esac
  else
    default_process
  fi
}

# ---------------------------
# Main flow
# ---------------------------
log "=== workflow_validate.sh starting ==="
ensure_example_files

log "PRE-VALIDATE: AJV ($SCHEMA vs $INPUT)"
if run_ajv "$SCHEMA" "$INPUT"; then
  log "AJV pre-validate: OK"
else
  log "AJV pre-validate: FAILED (see above)"
fi

log "PRE-VALIDATE: Python jsonschema ($SCHEMA vs $INPUT)"
if run_python_validate "$SCHEMA" "$INPUT"; then
  log "PY pre-validate: OK"
else
  log "PY pre-validate: FAILED"
fi

log "PROCESSING: invoking processor"
if ! run_processor; then
  log "PROCESS FAILED"; exit 30
fi

log "POST-VALIDATE: AJV ($OUTPUT_SCHEMA vs $OUTPUT)"
if run_ajv "$OUTPUT_SCHEMA" "$OUTPUT"; then
  log "AJV post-validate: OK"
else
  log "AJV post-validate: FAILED (see above)"
fi

log "POST-VALIDATE: Python jsonschema ($OUTPUT_SCHEMA vs $OUTPUT)"
if run_python_validate "$OUTPUT_SCHEMA" "$OUTPUT"; then
  log "PY post-validate: OK"
else
  log "PY post-validate: FAILED"
fi

log "=== workflow_validate.sh finished ==="
exit 0
