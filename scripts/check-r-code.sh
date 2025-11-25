#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

timestamp() { date --iso-8601=seconds; }

usage() {
    cat <<'USAGE'
Usage: check-r-code.sh -s SCRIPT_PATH [options]

Required arguments:
  -s, --script FILE        Path to the R script to inspect

Optional arguments:
  -t, --task NAME          Task identifier (used for default log location)
  -r, --report FILE        Explicit path for the Markdown report
  --logs DIR               Directory for report auto-numbering (default: tasks/<task>/logs)
  -h, --help               Show help message
USAGE
}

TASK_NAME=""
SCRIPT_PATH=""
REPORT_PATH=""
LOG_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--script)
            SCRIPT_PATH="$2"; shift 2 ;;
        -t|--task)
            TASK_NAME="$2"; shift 2 ;;
        -r|--report)
            REPORT_PATH="$2"; shift 2 ;;
        --logs)
            LOG_DIR="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2
            usage; exit 1 ;;
    esac
done

if [[ -z "$SCRIPT_PATH" ]]; then
    echo "error: --script is required" >&2
    usage
    exit 1
fi

if [[ ! -f "$SCRIPT_PATH" ]]; then
    echo "error: script not found: $SCRIPT_PATH" >&2
    exit 1
fi

if [[ -n "$TASK_NAME" && -z "$LOG_DIR" ]]; then
    LOG_DIR="$REPO_ROOT/tasks/$TASK_NAME/logs"
fi
if [[ -n "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR"
fi

if [[ -z "$REPORT_PATH" ]]; then
    if [[ -n "$LOG_DIR" ]]; then
        next_id=$(ls "$LOG_DIR"/code_check_*.md 2>/dev/null | sed -n 's/.*code_check_\([0-9][0-9]\).md/\1/p' | sort | tail -n1)
        if [[ -z "$next_id" ]]; then
            next_id="01"
        else
            printf -v next_id '%02d' $((10#$next_id + 1))
        fi
        REPORT_PATH="$LOG_DIR/code_check_${next_id}.md"
    else
        REPORT_PATH="$SCRIPT_PATH.code_check.md"
    fi
fi

mkdir -p "$(dirname "$REPORT_PATH")"

syntax_status="PASS"
syntax_details="R parser did not report issues."
syntax_output=""
if ! syntax_output=$(Rscript --vanilla -e "parse(file = '$SCRIPT_PATH')" 2>&1); then
    syntax_status="FAIL"
    syntax_details="R parser reported an error."
fi

lintr_status="SKIPPED"
lintr_details="lintr not installed; skipping style checks."
lintr_cmd_output=$(Rscript --vanilla - "$SCRIPT_PATH" <<'RS'
args <- commandArgs(trailingOnly = TRUE)
script <- args[[1]]
if (!requireNamespace("lintr", quietly = TRUE)) {
  cat("LINTR_MISSING\n")
  quit(status = 0)
}
issues <- lintr::lint(script)
if (length(issues) == 0) {
  cat("LINTR_OK\n")
} else {
  for (issue in issues) {
    cat(sprintf("%s:%s:%s:%s\n",
                issue$filename,
                issue$line_number,
                issue$type,
                issue$message))
  }
}
RS
)
if grep -q 'LINTR_MISSING' <<<"$lintr_cmd_output"; then
    lintr_status="SKIPPED"
    lintr_details="lintr package unavailable."
elif grep -q 'LINTR_OK' <<<"$lintr_cmd_output"; then
    lintr_status="PASS"
    lintr_details="No lint issues detected."
else
    lintr_status="WARN"
    lintr_details="See findings below."
fi

security_findings=$(rg --no-heading --line-number -e 'system\s*\(' -e 'eval\s*\(' -e 'parse\s*\(' -e 'assign\s*\(' "$SCRIPT_PATH" || true)
security_status="PASS"
if [[ -n "$security_findings" ]]; then
    security_status="WARN"
fi

dependencies=$(rg --no-heading -o -N -e '^[[:space:]]*(library|require)\(([^)#]+)\)' "$SCRIPT_PATH" | sed -E 's/^[^\(]+\(([^),]+).*/\1/' | tr -d "'\"") || true
readarray -t dependency_list <<<"$dependencies"
unique_dependencies=()
for pkg in "${dependency_list[@]}"; do
    pkg_trim="$(echo "$pkg" | xargs)"
    [[ -z "$pkg_trim" ]] && continue
    if [[ ! " ${unique_dependencies[*]} " =~ " $pkg_trim " ]]; then
        unique_dependencies+=("$pkg_trim")
    fi
done

dep_status="PASS"
missing_deps=()
if [[ ${#unique_dependencies[@]} -gt 0 ]]; then
    for pkg in "${unique_dependencies[@]}"; do
        if ! Rscript --vanilla -e "quit(status = ifelse(requireNamespace('$pkg', quietly = TRUE), 0, 42))" >/dev/null 2>&1; then
            missing_deps+=("$pkg")
        fi
    done
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        dep_status="WARN"
    fi
else
    dep_status="SKIPPED"
fi

cat >"$REPORT_PATH" <<REPORT
# R Code Check Report
- Script: $SCRIPT_PATH
- Generated: $(timestamp)

## Summary
| Check | Status | Notes |
| --- | --- | --- |
| Syntax | $syntax_status | $syntax_details |
| Lintr | $lintr_status | $lintr_details |
| Dangerous Calls | $security_status | $( [[ -n "$security_findings" ]] && echo "Review findings" || echo "None" ) |
| Dependencies | $dep_status | $( [[ -n "$missing_deps" ]] && echo "Missing: ${missing_deps[*]}" || echo "OK" ) |

## Syntax Output
```
${syntax_output:-<none>}
```

## Lintr Output
```
$lintr_cmd_output
```

## Dangerous Call Scan
```
${security_findings:-<none>}
```

## Dependency Check
```
${unique_dependencies[*]:-<none>}
```
REPORT

exit_code=0
if [[ "$syntax_status" == "FAIL" ]]; then
    exit_code=1
fi

cat <<SUMMARY
Report written to $REPORT_PATH
Syntax: $syntax_status, Lintr: $lintr_status, Security: $security_status, Dependencies: $dep_status
SUMMARY

exit "$exit_code"
