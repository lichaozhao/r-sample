#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

timestamp() { date --iso-8601=seconds; }

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

PROMPT_PATH="$TASK_DIR/tmp/validate_prompt.md"
CODEX_OUTPUT="$TASK_DIR/tmp/validate_codex.md"

summaries=()
failures=0

check_file_exists() {
    local label="$1" path="$2"
    if [[ -s "$path" ]]; then
        summaries+=("$label: PASS ($path)")
    else
        summaries+=("$label: FAIL ($path)")
        ((failures++))
    fi
}

for artifact in "${ARTIFACTS[@]}"; do
    if [[ "$artifact" == /* ]]; then
        RESOLVED_ARTIFACTS+=("$artifact")
    else
        RESOLVED_ARTIFACTS+=("$TASK_DIR/$artifact")
    fi
done

check_file_exists "Run log" "$RUN_LOG"
check_file_exists "Acceptance criteria" "$CRITERIA_PATH"
for idx in "${!RESOLVED_ARTIFACTS[@]}"; do
    original="${ARTIFACTS[$idx]}"
    resolved="${RESOLVED_ARTIFACTS[$idx]}"
    check_file_exists "Artifact $original" "$resolved"
done

# Build validation prompt for Codex
{
    echo "# 验收标准"
    cat "$CRITERIA_PATH"
    echo
    echo "# 执行日志摘要"
    tail -n "$MAX_PREVIEW" "$RUN_LOG"
    echo
    if [[ ${#RESOLVED_ARTIFACTS[@]} -gt 0 ]]; then
        echo "# 输出文件快照"
        for idx in "${!RESOLVED_ARTIFACTS[@]}"; do
            artifact="${RESOLVED_ARTIFACTS[$idx]}"
            label="${ARTIFACTS[$idx]}"
            echo "## $label ($artifact)"
            if [[ -s "$artifact" ]]; then
                line_count=$(wc -l <"$artifact" 2>/dev/null || echo 0)
                echo "行数: $line_count"
                echo '```'
                head -n "$MAX_PREVIEW" "$artifact"
                echo '```'
            else
                echo "文件缺失或为空。"
            fi
            echo
        done
    fi
} >"$PROMPT_PATH"

default_cmd='codex exec --output-last-message "$OUTPUT_FILE" < "$PROMPT_FILE"'
VALIDATE_CMD="${CODEX_VALIDATE_CMD_TEMPLATE:-$default_cmd}"
cmd_status=0
PROMPT_FILE="$PROMPT_PATH" OUTPUT_FILE="$CODEX_OUTPUT" TASK_DIR="$TASK_DIR" \
    bash -c "$VALIDATE_CMD" >/dev/null 2>&1 || cmd_status=$?

if (( cmd_status != 0 )); then
    echo "warning: Codex validation command failed (exit $cmd_status); continuing with local checks." >&2
fi

{
    echo "# 验证报告"
    echo "- 任务: $TASK_NAME"
    echo "- 生成时间: $(timestamp)"
    echo
    echo "## 本地校验"
    for summary in "${summaries[@]}"; do
        echo "- $summary"
    done
    echo
    echo "## Codex 评估"
    if [[ -s "$CODEX_OUTPUT" ]]; then
        cat "$CODEX_OUTPUT"
    else
        echo "Codex 验证未执行或无输出。"
    fi
} >"$REPORT_PATH"

if (( failures > 0 )); then
    echo "Validation failed. See $REPORT_PATH"
    exit 1
fi

echo "Validation succeeded. Report: $REPORT_PATH"
