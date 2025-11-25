#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$REPO_ROOT/templates"

timestamp() { date --iso-8601=seconds; }

log_info() { printf '[%s] %s\n' "$(timestamp)" "$*"; }

usage() {
    cat <<'USAGE'
Usage: enhance-requirement.sh -t TASK_NAME [options]

Required arguments:
  -t, --task NAME             Task identifier under tasks/<NAME>

Optional arguments:
  -i, --input FILE            Path to requirement_raw.md (default: tasks/<NAME>/requirement_raw.md)
  --enhanced FILE             Output path for requirement_enhanced.md (default: tasks/<NAME>/requirement_enhanced.md)
  --criteria FILE             Output path for acceptance_criteria.md (default: tasks/<NAME>/acceptance_criteria.md)
  --log FILE                  Log file (default: tasks/<NAME>/logs/enhancement.log)
  -h, --help                  Show this help message

Environment variables:
  CODEX_ENHANCE_CMD_TEMPLATE  Command template for requirement增强 (default: codex-cli generate ...)
  CODEX_CRITERIA_CMD_TEMPLATE Command template for验收标准 (default: same as above)
USAGE
}

render_template() {
    local template_path="$1"
    local placeholder="$2"
    local content_path="$3"
    local output_path="$4"
    python3 - "$template_path" "$placeholder" "$content_path" "$output_path" <<'PY'
import pathlib, sys
tmpl = pathlib.Path(sys.argv[1]).read_text()
placeholder = sys.argv[2]
content = pathlib.Path(sys.argv[3]).read_text().strip()
pathlib.Path(sys.argv[4]).write_text(tmpl.replace(placeholder, content))
PY
}

run_codex() {
    local template="$1" prompt_file="$2" output_file="$3" log_file="$4" stage="$5"
    local status=0
    PROMPT_FILE="$prompt_file" OUTPUT_FILE="$output_file" STAGE="$stage" TASK_DIR="$TASK_DIR" \
        bash -c "$template" >>"$log_file" 2>&1 || status=$?
    return "$status"
}

TASK_NAME=""
RAW_PATH=""
ENHANCED_PATH=""
CRITERIA_PATH=""
LOG_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--task)
            TASK_NAME="$2"; shift 2 ;;
        -i|--input)
            RAW_PATH="$2"; shift 2 ;;
        --enhanced)
            ENHANCED_PATH="$2"; shift 2 ;;
        --criteria)
            CRITERIA_PATH="$2"; shift 2 ;;
        --log)
            LOG_PATH="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1 ;;
    esac
done

if [[ -z "$TASK_NAME" ]]; then
    echo "error: --task is required" >&2
    usage
    exit 1
fi

TASK_DIR="$REPO_ROOT/tasks/$TASK_NAME"
mkdir -p "$TASK_DIR" "$TASK_DIR/logs"

RAW_PATH="${RAW_PATH:-$TASK_DIR/requirement_raw.md}"
ENHANCED_PATH="${ENHANCED_PATH:-$TASK_DIR/requirement_enhanced.md}"
CRITERIA_PATH="${CRITERIA_PATH:-$TASK_DIR/acceptance_criteria.md}"
LOG_PATH="${LOG_PATH:-$TASK_DIR/logs/enhancement.log}"

if [[ ! -f "$RAW_PATH" ]]; then
    echo "error: requirement file not found: $RAW_PATH" >&2
    exit 1
fi

ENHANCE_TEMPLATE="$TEMPLATE_DIR/requirement-enhancement-prompt.md"
CRITERIA_TEMPLATE="$TEMPLATE_DIR/acceptance-criteria-prompt.md"
if [[ ! -f "$ENHANCE_TEMPLATE" || ! -f "$CRITERIA_TEMPLATE" ]]; then
    echo "error: prompt templates not found under $TEMPLATE_DIR" >&2
    exit 1
fi

tmp_dir="$TASK_DIR/tmp"
mkdir -p "$tmp_dir"
ENHANCE_PROMPT="$tmp_dir/enhance_prompt.md"
CRITERIA_PROMPT="$tmp_dir/criteria_prompt.md"

render_template "$ENHANCE_TEMPLATE" '{{REQUIREMENT_RAW}}' "$RAW_PATH" "$ENHANCE_PROMPT"

default_codex_cmd='codex-cli generate --prompt-file "$PROMPT_FILE" --language markdown --output "$OUTPUT_FILE"'
ENHANCE_CMD="${CODEX_ENHANCE_CMD_TEMPLATE:-$default_codex_cmd}"
CRITERIA_CMD="${CODEX_CRITERIA_CMD_TEMPLATE:-$default_codex_cmd}"

log_info "[enhance] Generating enhanced requirement for task '$TASK_NAME'"
if ! run_codex "$ENHANCE_CMD" "$ENHANCE_PROMPT" "$ENHANCED_PATH" "$LOG_PATH" enhance; then
    echo "error: Codex enhancement command failed; check $LOG_PATH" >&2
    exit 1
fi

render_template "$CRITERIA_TEMPLATE" '{{REQUIREMENT_ENHANCED}}' "$ENHANCED_PATH" "$CRITERIA_PROMPT"
log_info "[criteria] Generating acceptance criteria"
if ! run_codex "$CRITERIA_CMD" "$CRITERIA_PROMPT" "$CRITERIA_PATH" "$LOG_PATH" criteria; then
    echo "error: Codex criteria command failed; check $LOG_PATH" >&2
    exit 1
fi

log_info "Enhancement artifacts written to:\n- $ENHANCED_PATH\n- $CRITERIA_PATH"
