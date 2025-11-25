#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$REPO_ROOT/templates"
source "$SCRIPT_DIR/docker-utils.sh"

STAGE_ORDER=(enhance generate execute validate)
declare -A STAGE_INDEX=( [enhance]=1 [generate]=2 [execute]=3 [validate]=4 )

log() {
    local level="$1"; shift
    printf '[%s] [%s] %s\n' "$(date --iso-8601=seconds)" "$level" "$*"
}

die() {
    log ERROR "$*"
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: r-workflow-auto.sh -t TASK_NAME [options]

Required arguments:
  -t, --task NAME            Task identifier under tasks/<NAME>

Optional arguments:
  -i, --input FILE           Path to requirement_raw.md to copy into the task
  -d, --data PATH            Data directory/file copied into tasks/<NAME>/data
  --max-iters N              Maximum iterations for regeneration loop (default: 5)
  --skip-docker              Skip container execution & validation; stop after static checks
  --from-stage STAGE         Start from stage enhance|generate|execute|validate (default: enhance)
  --artifact PATH            Expected output artifact to validate (repeatable)
  --image TAG                Docker image tag (default: codex-r-runner:latest)
  --notes FILE               Override notes file path
  -h, --help                 Show this help message

Environment variables:
  CODEX_CODEGEN_CMD_TEMPLATE Command template for code generation (default codex-cli ...)
  CODEX_CODEFIX_CMD_TEMPLATE Command template for fix iterations
USAGE
}

resolve_path() {
    local path="$1"
    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s/%s\n' "$(pwd)" "$path"
    fi
}

render_code_prompt() {
    local template="$1" output="$2" req="$3" criteria="$4" context="$5"
    python3 - "$template" "$output" "$req" "$criteria" "$context" <<'PY'
import pathlib, sys
tmpl = pathlib.Path(sys.argv[1]).read_text()
output_path = pathlib.Path(sys.argv[2])
req = pathlib.Path(sys.argv[3]).read_text().strip()
criteria = pathlib.Path(sys.argv[4]).read_text().strip()
context = pathlib.Path(sys.argv[5]).read_text().strip()
rendered = (tmpl
            .replace('{{REQUIREMENT_ENHANCED}}', req)
            .replace('{{ACCEPTANCE_CRITERIA}}', criteria)
            .replace('{{ADDITIONAL_CONTEXT}}', context))
output_path.write_text(rendered)
PY
}

append_note() {
    local iteration="$1" status="$2" details="$3" script_path="$4" check_report="$5" run_log="$6" validation_report="$7"
    {
        printf '## Iteration %s (%s)\n' "$iteration" "$(date --iso-8601=seconds)"
        printf '- Status: %s\n' "$status"
        printf '- Details: %s\n' "$details"
        printf '- Script: %s\n' "${script_path:-n/a}"
        printf '- Check report: %s\n' "${check_report:-n/a}"
        printf '- Run log: %s\n' "${run_log:-n/a}"
        printf '- Validation: %s\n\n' "${validation_report:-n/a}"
    } >>"$NOTES_FILE"
}

TASK_NAME=""
INPUT_PATH=""
DATA_PATH=""
MAX_ITERS=5
SKIP_DOCKER=0
FROM_STAGE="enhance"
ARTIFACTS=()
IMAGE_TAG="${R_WORKFLOW_IMAGE:-codex-r-runner:latest}"
NOTES_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--task)
            TASK_NAME="$2"; shift 2 ;;
        -i|--input)
            INPUT_PATH="$2"; shift 2 ;;
        -d|--data)
            DATA_PATH="$2"; shift 2 ;;
        --max-iters)
            MAX_ITERS="$2"; shift 2 ;;
        --skip-docker)
            SKIP_DOCKER=1; shift ;;
        --from-stage)
            FROM_STAGE="$2"; shift 2 ;;
        --artifact)
            ARTIFACTS+=("$2"); shift 2 ;;
        --image)
            IMAGE_TAG="$2"; shift 2 ;;
        --notes)
            NOTES_FILE="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1 ;;
    esac
done

[[ -n "$TASK_NAME" ]] || die "--task is required"
if [[ -n "$INPUT_PATH" ]]; then
    INPUT_PATH="$(resolve_path "$INPUT_PATH")"
fi
if [[ -n "$DATA_PATH" ]]; then
    DATA_PATH="$(resolve_path "$DATA_PATH")"
fi
if ! [[ "$MAX_ITERS" =~ ^[0-9]+$ ]] || (( MAX_ITERS < 1 )); then
    die "--max-iters must be a positive integer"
fi
if [[ -z "${STAGE_INDEX[$FROM_STAGE]:-}" ]]; then
    die "Unknown --from-stage value: $FROM_STAGE"
fi

TASK_DIR="$REPO_ROOT/tasks/$TASK_NAME"
TASK_LOGS="$TASK_DIR/logs"
TASK_TMP="$TASK_DIR/tmp"
DATA_DIR="$TASK_DIR/data"
OUTPUT_DIR="$TASK_DIR/output"
mkdir -p "$TASK_DIR" "$TASK_LOGS" "$TASK_TMP" "$OUTPUT_DIR"

if [[ -z "$NOTES_FILE" ]]; then
    NOTES_FILE="$TASK_DIR/notes.md"
fi
if [[ ! -f "$NOTES_FILE" ]]; then
    {
        printf '# Task %s notes\n\n' "$TASK_NAME"
        printf '- Created: %s\n' "$(date --iso-8601=seconds)"
    } >"$NOTES_FILE"
fi

if [[ -n "$INPUT_PATH" ]]; then
    cp "$INPUT_PATH" "$TASK_DIR/requirement_raw.md"
fi
if [[ -n "$DATA_PATH" ]]; then
    mkdir -p "$DATA_DIR"
    if [[ -d "$DATA_PATH" ]]; then
        if command -v rsync >/dev/null 2>&1; then
            rsync -a "$DATA_PATH"/ "$DATA_DIR"/
        else
            cp -a "$DATA_PATH"/. "$DATA_DIR"/
        fi
    else
        cp "$DATA_PATH" "$DATA_DIR"/
    fi
fi

REQUIREMENT_RAW="$TASK_DIR/requirement_raw.md"
REQUIREMENT_ENHANCED="$TASK_DIR/requirement_enhanced.md"
ACCEPTANCE_CRITERIA="$TASK_DIR/acceptance_criteria.md"
REPORT_FILE="$TASK_DIR/report.md"

[[ -f "$REQUIREMENT_RAW" ]] || die "requirement_raw.md missing under $TASK_DIR"

run_enhancement_stage() {
    if (( ${STAGE_INDEX[$FROM_STAGE]} > ${STAGE_INDEX[enhance]} )); then
        log INFO "Skipping enhancement stage per --from-stage"
        return
    fi
    log INFO "Running requirement enhancement"
    "$SCRIPT_DIR/enhance-requirement.sh" -t "$TASK_NAME" -i "$REQUIREMENT_RAW"
}

build_context_file() {
    local context_file="$1" iteration="$2" reason="$3" previous_script="$4" check_report="$5" run_log="$6" validation_report="$7"
    {
        printf '## 迭代 #%s 上下文\n' "$iteration"
        if [[ -n "$reason" ]]; then
            printf '- 上一轮失败原因：%s\n\n' "$reason"
        fi
        if [[ -n "$previous_script" && -f "$previous_script" ]]; then
            echo '### 上一版脚本摘要'
            echo '```r'
            tail -n 200 "$previous_script"
            echo '```'
        fi
        if [[ -n "$check_report" && -f "$check_report" ]]; then
            echo '### 静态检查摘要'
            tail -n 80 "$check_report"
        fi
        if [[ -n "$run_log" && -f "$run_log" ]]; then
            printf '\n### 执行日志摘要\n'
            tail -n 80 "$run_log"
        fi
        if [[ -n "$validation_report" && -f "$validation_report" ]]; then
            printf '\n### 验证报告摘要\n'
            tail -n 80 "$validation_report"
        fi
        if [[ -z "$previous_script$check_report$run_log$validation_report" ]]; then
            echo '首次迭代，暂无历史上下文。'
        fi
    } >"$context_file"
}

run_codex_generation() {
    local prompt_file="$1" output_file="$2" log_file="$3" iteration="$4" is_fix="$5"
    local default_cmd='codex-cli generate --prompt-file "$PROMPT_FILE" --language r --output "$OUTPUT_FILE"'
    local template="$default_cmd"
    if [[ "$is_fix" == "true" ]]; then
        template="${CODEX_CODEFIX_CMD_TEMPLATE:-$default_cmd}"
    else
        template="${CODEX_CODEGEN_CMD_TEMPLATE:-$default_cmd}"
    fi
    PROMPT_FILE="$prompt_file" OUTPUT_FILE="$output_file" ITERATION="$iteration" TASK_DIR="$TASK_DIR" \
        bash -c "$template" >"$log_file" 2>&1
}

run_static_check() {
    local script_path="$1" iteration_tag="$2"
    local report_path="$TASK_LOGS/code_check_${iteration_tag}.md"
    if "$SCRIPT_DIR/check-r-code.sh" -s "$script_path" -r "$report_path" >/dev/null; then
        echo "$report_path"
        return 0
    else
        echo "$report_path"
        return 1
    fi
}

run_container_stage() {
    local script_path="$1" iteration_tag="$2"
    local run_log="$TASK_LOGS/run_${iteration_tag}.log"
    local container_name="codex-r-${TASK_NAME}-${iteration_tag}"
    if run_r_in_container "$script_path" "$TASK_DIR" "$IMAGE_TAG" "$container_name" >"$run_log" 2>&1; then
        echo "$run_log"
        return 0
    fi
    echo "$run_log"
    return 1
}

run_validation_stage() {
    local run_log="$1" iteration_tag="$2"
    local report_path="$TASK_LOGS/validation_${iteration_tag}.md"
    local args=(--task "$TASK_NAME" --criteria "$ACCEPTANCE_CRITERIA" --run-log "$run_log" --report "$report_path")
    for artifact in "${ARTIFACTS[@]}"; do
        local resolved="$artifact"
        if [[ "$resolved" != /* ]]; then
            resolved="$TASK_DIR/$resolved"
        fi
        args+=(--artifact "$resolved")
    done
    if "$SCRIPT_DIR/validate-result.sh" "${args[@]}" >/dev/null; then
        echo "$report_path"
        return 0
    fi
    echo "$report_path"
    return 1
}

run_iteration_loop() {
    local success=0
    local last_failure=""
    local repeat_failures=0
    local previous_failure=""
    local iteration=1
    local last_script=""
    LAST_SUCCESS_ITER=""
    LAST_CHECK_REPORT=""
    LAST_RUN_LOG=""
    LAST_VALIDATION_REPORT=""
    while (( iteration <= MAX_ITERS )); do
        printf -v tag '%02d' "$iteration"
        log INFO "Iteration $iteration starting"
        local context_file="$TASK_TMP/context_${tag}.md"
        build_context_file "$context_file" "$iteration" "$last_failure" "$last_script" "$LAST_CHECK_REPORT" "$LAST_RUN_LOG" "$LAST_VALIDATION_REPORT"
        local template="$TEMPLATE_DIR/code-generation-prompt.md"
        if (( iteration > 1 )); then
            template="$TEMPLATE_DIR/code-fix-prompt.md"
        fi
        local prompt_file="$TASK_TMP/prompt_${tag}.md"
        render_code_prompt "$template" "$prompt_file" "$REQUIREMENT_ENHANCED" "$ACCEPTANCE_CRITERIA" "$context_file"
        local script_path="$TASK_DIR/script_v${tag}.R"
        local codex_log="$TASK_LOGS/codex_${tag}.log"
        local is_fix="false"
        (( iteration > 1 )) && is_fix="true"
        if ! run_codex_generation "$prompt_file" "$script_path" "$codex_log" "$iteration" "$is_fix"; then
            append_note "$tag" "codex_failed" "Codex 生成失败" "$script_path" "" "" ""
            die "Codex generation failed; see $codex_log"
        fi
        last_script="$script_path"
        LAST_SCRIPT_PATH="$script_path"

        local check_status=0
        local check_report
        check_report=$(run_static_check "$script_path" "$tag") || check_status=$?
        LAST_CHECK_REPORT="$check_report"
        if [[ ! -s "$script_path" ]]; then
            append_note "$tag" "empty_script" "生成脚本为空" "$script_path" "$check_report" "" ""
            die "Generated script is empty for iteration $iteration"
        fi

        if (( check_status != 0 )); then
            last_failure="静态检查失败"
            if [[ "$last_failure" == "$previous_failure" ]]; then
                ((repeat_failures++))
            else
                repeat_failures=1
            fi
            previous_failure="$last_failure"
            append_note "$tag" "check_failed" "$last_failure" "$script_path" "$check_report" "" ""
            if (( repeat_failures >= 2 )); then
                die "静态检查连续失败两次，停止自动修复"
            fi
            (( iteration++ ))
            continue
        fi

        if (( SKIP_DOCKER )); then
            cp "$script_path" "$TASK_DIR/script_final.R"
            append_note "$tag" "success" "跳过执行，静态检查通过" "$script_path" "$check_report" "" ""
            LAST_SUCCESS_ITER="$tag"
            success=1
            break
        fi

        local run_status=0
        local run_log
        run_log=$(run_container_stage "$script_path" "$tag") || run_status=$?
        LAST_RUN_LOG="$run_log"
        if (( run_status != 0 )); then
            last_failure="容器执行失败"
            append_note "$tag" "run_failed" "$last_failure" "$script_path" "$check_report" "$run_log" ""
            if [[ "$last_failure" == "$previous_failure" ]]; then
                ((repeat_failures++))
            else
                repeat_failures=1
            fi
            previous_failure="$last_failure"
            if (( repeat_failures >= 2 )); then
                die "容器执行连续失败两次，停止自动修复"
            fi
            (( iteration++ ))
            continue
        fi

        local validation_status=0
        local validation_report
        validation_report=$(run_validation_stage "$run_log" "$tag") || validation_status=$?
        LAST_VALIDATION_REPORT="$validation_report"
        if (( validation_status != 0 )); then
            last_failure="结果验证失败"
            append_note "$tag" "validation_failed" "$last_failure" "$script_path" "$check_report" "$run_log" "$validation_report"
            if [[ "$last_failure" == "$previous_failure" ]]; then
                ((repeat_failures++))
            else
                repeat_failures=1
            fi
            previous_failure="$last_failure"
            if (( repeat_failures >= 2 )); then
                die "结果验证连续失败两次，停止自动修复"
            fi
            (( iteration++ ))
            continue
        fi

        cp "$script_path" "$TASK_DIR/script_final.R"
        cp "$run_log" "$TASK_LOGS/run_final.log"
        cp "$validation_report" "$TASK_LOGS/validation_final.md"
        append_note "$tag" "success" "所有阶段通过" "$script_path" "$check_report" "$run_log" "$validation_report"
        LAST_SUCCESS_ITER="$tag"
        success=1
        break
    done

    if (( ! success )); then
        die "Workflow failed after $MAX_ITERS iterations"
    fi
}

if [[ ! -f "$TEMPLATE_DIR/code-generation-prompt.md" ]]; then
    die "Missing code-generation prompt template"
fi
if [[ ! -f "$TEMPLATE_DIR/code-fix-prompt.md" ]]; then
    die "Missing code-fix prompt template"
fi

if (( ${STAGE_INDEX[$FROM_STAGE]} <= ${STAGE_INDEX[enhance]} )); then
    run_enhancement_stage
elif [[ ! -f "$REQUIREMENT_ENHANCED" || ! -f "$ACCEPTANCE_CRITERIA" ]]; then
    die "Enhanced requirement or acceptance criteria missing; rerun from enhance stage."
fi

if (( ${STAGE_INDEX[$FROM_STAGE]} <= ${STAGE_INDEX[generate]} )); then
    run_iteration_loop
else
    log INFO "Skipping generation stage per --from-stage"
fi

if (( ${STAGE_INDEX[$FROM_STAGE]} > ${STAGE_INDEX[generate]} )); then
    if (( SKIP_DOCKER )); then
        log INFO "skip-docker flag set; nothing else to run"
    else
        if (( ${STAGE_INDEX[$FROM_STAGE]} <= ${STAGE_INDEX[execute]} )); then
            [[ -f "$TASK_DIR/script_final.R" ]] || die "script_final.R missing for execution"
            run_log=$(run_container_stage "$TASK_DIR/script_final.R" "manual") || true
            log INFO "Execute-only run complete; log: $run_log"
        fi
        if (( ${STAGE_INDEX[$FROM_STAGE]} <= ${STAGE_INDEX[validate]} )); then
            [[ -n "$run_log" && -f "$run_log" ]] || die "Run log missing for validation"
            report=$(run_validation_stage "$run_log" "manual") || true
            log INFO "Validation-only run wrote $report"
        fi
    fi
fi

status_label="SUCCESS"
if [[ -z "${LAST_SUCCESS_ITER:-}" ]]; then
    status_label="FAILED"
fi

{
    echo "# Task Report"
    echo "- Task: $TASK_NAME"
    echo "- Status: $status_label"
    echo "- Iterations attempted: $MAX_ITERS"
    if [[ -n "${LAST_SUCCESS_ITER:-}" ]]; then
        echo "- Successful iteration: $LAST_SUCCESS_ITER"
    fi
    echo "- skip-docker: $SKIP_DOCKER"
    echo "- Generated at: $(date --iso-8601=seconds)"
    echo
    echo "## Key Artifacts"
    echo "- Enhanced requirement: ${REQUIREMENT_ENHANCED}"
    echo "- Acceptance criteria: ${ACCEPTANCE_CRITERIA}"
    if [[ -f "$TASK_DIR/script_final.R" ]]; then
        echo "- Final script: $TASK_DIR/script_final.R"
    fi
    if [[ -f "$TASK_LOGS/run_final.log" ]]; then
        echo "- Run log: $TASK_LOGS/run_final.log"
    fi
    if [[ -f "$TASK_LOGS/validation_final.md" ]]; then
        echo "- Validation report: $TASK_LOGS/validation_final.md"
    fi
} >"$REPORT_FILE"

log INFO "Workflow finished. Report: $REPORT_FILE"
