#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_NAME="validate-result.sh"
COLOR_BANNER="\033[1;35m"
COLOR_RESET="\033[0m"

timestamp() { date --iso-8601=seconds; }

log_info() { printf '[%s] [INFO] %s\n' "$(timestamp)" "$*" >&2; }
log_warn() { printf '[%s] [WARN] %s\n' "$(timestamp)" "$*" >&2; }

announce_start() {
    printf "%b[%s] %s invoked%b\n" "$COLOR_BANNER" "$(timestamp)" "$SCRIPT_NAME" "$COLOR_RESET" >&2
}

usage() {
    cat <<'USAGE'
Usage: validate-result.sh -t TASK_NAME --criteria FILE --run-log FILE [--artifact PATH ...]

Required arguments:
  -t, --task NAME          Task identifier used to resolve default directories
  --criteria FILE          Path to acceptance_criteria.md
  --run-log FILE           Path to execution log to inspect

Optional arguments:
  -a, --artifact FILE      Output artifact to validate (repeatable)
  --report FILE            Path to validation report (default: tasks/<task>/logs/validation_##.md)
  --max-preview LINES      Lines of each artifact/log snippet included in prompt (default: 40)
  -h, --help               Show this message

Environment variables:
  CODEX_VALIDATE_CMD_TEMPLATE   Command template for Codex validation (default: codex exec --output-last-message ...)
USAGE
}

announce_start

TASK_NAME=""
CRITERIA_PATH=""
RUN_LOG=""
REPORT_PATH=""
MAX_PREVIEW=40
ARTIFACTS=()
RESOLVED_ARTIFACTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--task)
            TASK_NAME="$2"; shift 2 ;;
        --criteria)
            CRITERIA_PATH="$2"; shift 2 ;;
        --run-log)
            RUN_LOG="$2"; shift 2 ;;
        -a|--artifact)
            ARTIFACTS+=("$2"); shift 2 ;;
        --report)
            REPORT_PATH="$2"; shift 2 ;;
        --max-preview)
            MAX_PREVIEW="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage; exit 1 ;;
    esac
done

log_info "Args parsed task=$TASK_NAME run-log=$RUN_LOG criteria=$CRITERIA_PATH report=${REPORT_PATH:-auto}"

if [[ -z "$TASK_NAME" || -z "$CRITERIA_PATH" || -z "$RUN_LOG" ]]; then
    echo "error: --task, --criteria, and --run-log are required" >&2
    usage
    exit 1
fi

TASK_DIR="$REPO_ROOT/tasks/$TASK_NAME"
LOG_DIR="$TASK_DIR/logs"
mkdir -p "$LOG_DIR" "$TASK_DIR/tmp"

if [[ ! -f "$CRITERIA_PATH" ]]; then
    echo "error: acceptance criteria not found: $CRITERIA_PATH" >&2
    exit 1
fi
if [[ ! -f "$RUN_LOG" ]]; then
    echo "error: run log not found: $RUN_LOG" >&2
    exit 1
fi

if ! [[ "$MAX_PREVIEW" =~ ^[0-9]+$ ]]; then
    echo "error: --max-preview must be a positive integer" >&2
    exit 1
fi

if [[ -z "$REPORT_PATH" ]]; then
    shopt -s nullglob
    existing_reports=("$LOG_DIR"/validation_*.md)
    shopt -u nullglob
    if (( ${#existing_reports[@]} == 0 )); then
        next_id="01"
    else
        last_id=$(printf '%s\n' "${existing_reports[@]}" | sed -n 's/.*validation_\([0-9][0-9]\).md/\1/p' | sort | tail -n1)
        if [[ -z "$last_id" ]]; then
            next_id="01"
        else
            printf -v next_id '%02d' $((10#$last_id + 1))
        fi
    fi
    REPORT_PATH="$LOG_DIR/validation_${next_id}.md"
fi

log_info "Report path resolved: $REPORT_PATH"

summaries=()
failures=0
declare -a CHECK_LABELS=()
declare -a CHECK_PATHS=()
declare -A SEEN_PATHS=()

resolve_path() {
    local raw="$1"
    if [[ -z "$raw" ]]; then
        return 1
    fi
    if [[ "$raw" == *'<'* || "$raw" == *'>'* ]]; then
        return 1
    fi
    case "$raw" in
        /workspace/*)
            printf '%s' "$TASK_DIR${raw#/workspace}"
            ;;
        tasks/*)
            printf '%s' "$REPO_ROOT/$raw"
            ;;
        output/*)
            printf '%s' "$TASK_DIR/$raw"
            ;;
        logs/*)
            printf '%s' "$TASK_DIR/$raw"
            ;;
        /*)
            printf '%s' "$raw"
            ;;
        *)
            printf '%s' "$TASK_DIR/output/$raw"
            ;;
    esac
}

add_check_item() {
    local label="$1" raw="$2"
    local resolved
    resolved=$(resolve_path "$raw") || resolved="$raw"
    if [[ -z "$resolved" ]]; then
        return 0
    fi
    if [[ -n "${SEEN_PATHS[$resolved]:-}" ]]; then
        return 0
    fi
    SEEN_PATHS["$resolved"]=1
    CHECK_LABELS+=("$label")
    CHECK_PATHS+=("$resolved")
}

extract_requirement_artifacts() {
    local requirement_file="$TASK_DIR/requirement_enhanced.md"
    [[ -f "$requirement_file" ]] || return 0
    local raw_paths
    raw_paths=$(python3 - "$requirement_file" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
try:
    text = path.read_text()
except Exception:
    sys.exit(0)
capture = False
paths = []
for line in text.splitlines():
    stripped = line.strip()
    if stripped.startswith('##'):
        capture = '结果交付' in stripped
        continue
    if not capture or not stripped:
        continue
    matches = re.findall(r'`([^`]+)`', stripped)
    if not matches:
        matches = re.findall(r'(/workspace/[\w./\-]+)', stripped)
    for m in matches:
        if '<' in m or '>' in m:
            continue
        if re.search(r'\.(csv|png|md|log|txt)$', m, re.IGNORECASE):
            paths.append(m.strip())
if paths:
    print('\n'.join(paths))
PY
) || raw_paths=""
    [[ -z "$raw_paths" ]] && return 0
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        add_check_item "Result item: $item" "$item"
    done <<<"$raw_paths"
}

check_file_exists() {
    local label="$1" path="$2"
    if [[ -s "$path" ]]; then
        summaries+=("$label: PASS ($path)")
    else
        summaries+=("$label: FAIL ($path)")
        ((++failures))
    fi
    return 0
}

add_check_item "Run log" "$RUN_LOG"
add_check_item "Acceptance criteria" "$CRITERIA_PATH"

for artifact in "${ARTIFACTS[@]}"; do
    add_check_item "Artifact (CLI) $artifact" "$artifact"
done

extract_requirement_artifacts

log_info "Total check targets: ${#CHECK_LABELS[@]}"

for idx in "${!CHECK_LABELS[@]}"; do
    check_file_exists "${CHECK_LABELS[$idx]}" "${CHECK_PATHS[$idx]}"
done

{
    echo "# 验证报告"
    echo "- 任务: $TASK_NAME"
    echo "- 生成时间: $(timestamp)"
    echo
    echo "## 本地校验"
    if [[ ${#summaries[@]} -eq 0 ]]; then
        echo "- 未找到需要检查的文件"
    else
        for summary in "${summaries[@]}"; do
            echo "- $summary"
        done
    fi
} >"$REPORT_PATH"

if (( failures > 0 )); then
    echo "Validation failed. See $REPORT_PATH"
    exit 1
fi

log_info "Validation succeeded"
echo "Validation succeeded. Report: $REPORT_PATH"
