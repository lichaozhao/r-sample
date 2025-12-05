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
  -t, --task NAME          Task identifier (same as tasks/<NAME>)
  --criteria FILE          Path to acceptance_criteria.md
  --run-log FILE           Path to run log for reference

Optional arguments:
  -a, --artifact FILE      Additional artifact paths that必须存在 (repeatable)
  --report FILE            Validation report path (default: tasks/<task>/logs/validation_##.md)
  --skip-codex             仅做本地存在性检查，跳过 Codex 核验
  -h, --help               Show this message

Environment:
  CODEX_VALIDATE_CMD_TEMPLATE   Override Codex CLI command模板（默认: codex exec --output-last-message "$OUTPUT_CAPTURE" "$PROMPT_TEXT"）
USAGE
}

announce_start

TASK_NAME=""
CRITERIA_PATH=""
RUN_LOG=""
REPORT_PATH=""
SKIP_CODEX="false"
ARTIFACTS=()

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
        --skip-codex)
            SKIP_CODEX="true"; shift ;;
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
OUTPUT_DIR="$TASK_DIR/output"
mkdir -p "$LOG_DIR"

if [[ -z "$REPORT_PATH" ]]; then
    shopt -s nullglob
    existing=("$LOG_DIR"/validation_*.md)
    shopt -u nullglob
    if (( ${#existing[@]} == 0 )); then
        next_id="01"
    else
        last=$(printf '%s\n' "${existing[@]}" | sed -n 's/.*validation_\([0-9][0-9]\).md/\1/p' | sort | tail -n1)
        if [[ -z "$last" ]]; then
            next_id="01"
        else
            printf -v next_id '%02d' $((10#$last + 1))
        fi
    fi
    REPORT_PATH="$LOG_DIR/validation_${next_id}.md"
fi

log_info "Args parsed task=$TASK_NAME run-log=$RUN_LOG criteria=$CRITERIA_PATH report=$REPORT_PATH"

summaries=()
failures=0

check_path() {
    local label="$1" path="$2" kind="${3:-file}"
    local ok=1
    case "$kind" in
        file)
            [[ -s "$path" ]] || ok=0 ;;
        dir)
            [[ -d "$path" ]] || ok=0 ;;
        any)
            [[ -e "$path" ]] || ok=0 ;;
    esac
    if (( ok )); then
        summaries+=("$label: PASS ($path)")
    else
        summaries+=("$label: FAIL ($path)")
        ((++failures))
    fi
}

check_path "Run log" "$RUN_LOG" file
check_path "Acceptance criteria" "$CRITERIA_PATH" file
check_path "Output directory" "$OUTPUT_DIR" dir

for artifact in "${ARTIFACTS[@]}"; do
    check_path "Artifact $artifact" "$artifact" any
done

CODEX_OUTPUT_FILE="$LOG_DIR/validation_codex.md"
CODEX_LOG_FILE="$LOG_DIR/validation_codex_cli.log"
CODEX_VERDICT="SKIPPED"
CODEX_NOTE="Codex 未执行"

build_codex_prompt() {
    local prompt
    read -r -d '' prompt <<EOF || true
你是自动化验收助手。请操作当前仓库完成以下步骤：
1. 阅读文件 "$CRITERIA_PATH"，理解文中列出的产物及其路径要求。
2. 根据文档描述，在 Shell 中检查这些路径是否真实存在且非空，重点关注 "$OUTPUT_DIR" 及其子目录。
3. 可自由使用诸如 cat/ls/find/head 等命令；若发现缺失或空文件，请记录证据。
4. 最终请仅输出一次如下格式：
VERDICT: PASS 或 FAIL
DETAILS:
- 针对每条验收要求，说明是否满足及所用证据（含路径与命令输出摘要）。
MISSING:
- 若有缺失文件或日志，请逐条列出；若全满足，写 "无"。
EOF
    printf '%s' "$prompt"
}

run_codex_review() {
    if [[ "$SKIP_CODEX" == "true" ]]; then
        CODEX_NOTE="已通过 --skip-codex 跳过 Codex 验收"
        return 0
    fi
    if ! command -v codex >/dev/null 2>&1; then
        CODEX_VERDICT="ERROR"
        CODEX_NOTE="codex 命令未找到，无法执行自动验收"
        log_warn "$CODEX_NOTE"
        return 1
    fi
    local prompt_text
    prompt_text="$(build_codex_prompt)"
    local default_cmd='codex exec --output-last-message "$OUTPUT_CAPTURE" "$PROMPT_TEXT"'
    local template="${CODEX_VALIDATE_CMD_TEMPLATE:-$default_cmd}"
    PROMPT_TEXT="$prompt_text" OUTPUT_CAPTURE="$CODEX_OUTPUT_FILE" TASK_DIR="$TASK_DIR" \
        bash -c "$template" >"$CODEX_LOG_FILE" 2>&1 || {
            CODEX_VERDICT="ERROR"
            CODEX_NOTE="Codex 命令执行失败，日志: $CODEX_LOG_FILE"
            return 1
        }
    local verdict_line
    if verdict_line=$(grep -m1 -E '^VERDICT:' "$CODEX_OUTPUT_FILE" 2>/dev/null); then
        local decision
        decision=$(sed -n 's/^VERDICT:[[:space:]]*//p' <<<"$verdict_line")
        case "$decision" in
            PASS|FAIL)
                CODEX_VERDICT="$decision"
                CODEX_NOTE="详见 $CODEX_OUTPUT_FILE"
                [[ "$decision" == "PASS" ]] || return 1
                return 0
                ;;
        esac
    fi
    CODEX_VERDICT="ERROR"
    CODEX_NOTE="未能解析 Codex 输出中的 VERDICT，参见 $CODEX_OUTPUT_FILE"
    return 1
}

run_codex_review || ((++failures))

{
    echo "# 验证报告"
    echo "- 任务: $TASK_NAME"
    echo "- 生成时间: $(timestamp)"
    echo
    echo "## 本地存在性检查"
    for summary in "${summaries[@]}"; do
        echo "- $summary"
    done
    echo
    echo "## Codex 验收"
    echo "- 状态: $CODEX_VERDICT"
    echo "- 说明: $CODEX_NOTE"
    echo "- CLI 日志: $CODEX_LOG_FILE"
    echo "- Codex 输出: $CODEX_OUTPUT_FILE"
    if [[ -f "$CODEX_OUTPUT_FILE" ]]; then
        echo
        cat "$CODEX_OUTPUT_FILE"
    fi
} >"$REPORT_PATH"

if (( failures > 0 )); then
    echo "Validation failed. See $REPORT_PATH"
    exit 1
fi

log_info "Validation succeeded"
echo "Validation succeeded. Report: $REPORT_PATH"
