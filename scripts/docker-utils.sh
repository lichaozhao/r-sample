#!/usr/bin/env bash
set -euo pipefail

# Docker helper utilities used by the workflow scripts. The functions can be sourced
# or invoked via the CLI interface provided at the bottom of this file.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKER_DIR="$REPO_ROOT/docker"
DOCKERFILE="$DOCKER_DIR/Dockerfile.r-runner"
DEFAULT_IMAGE_TAG=${R_WORKFLOW_IMAGE:-codex-r-runner:latest}
DOCKER_BIN=${DOCKER_BIN:-docker}

log() {
    local level="$1"; shift
    printf '[%s] %s\n' "$level" "$*" >&2
}

ensure_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        log ERROR "Required file not found: $path"
        exit 1
    fi
}

check_docker_available() {
    if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
        log ERROR "Docker command '$DOCKER_BIN' is not in PATH"
        return 1
    fi
    if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
        log ERROR "Docker daemon is not reachable. Ensure it is running and you have the right permissions."
        return 1
    fi
    log INFO "Docker is available via '$DOCKER_BIN'."
}

build_r_image() {
    local tag="${1:-$DEFAULT_IMAGE_TAG}"
    ensure_file "$DOCKERFILE"
    check_docker_available
    log INFO "Building R runner image '$tag' from $DOCKERFILE"
    "$DOCKER_BIN" build -f "$DOCKERFILE" -t "$tag" "$REPO_ROOT"
    log INFO "Image '$tag' built successfully."
}

run_r_in_container() {
    if [[ $# -lt 2 ]]; then
        log ERROR "usage: run_r_in_container <script_path> <task_dir> [image_tag] [container_name]"
        return 1
    fi
    local script_path="$1"
    local task_dir="$2"
    local image_tag="${3:-$DEFAULT_IMAGE_TAG}"
    local container_name="${4:-codex-r-runner-$(date +%s)}"

    if [[ ! -f "$script_path" ]]; then
        log ERROR "Script '$script_path' does not exist"
        return 1
    fi
    if [[ ! -d "$task_dir" ]]; then
        log ERROR "Task directory '$task_dir' not found"
        return 1
    fi

    local abs_task_dir
    abs_task_dir="$(cd "$task_dir" && pwd)"
    local script_basename
    script_basename="$(basename "$script_path")"

    if [[ ! -f "$abs_task_dir/$script_basename" ]]; then
        log ERROR "Script must reside under the task directory. Expected $abs_task_dir/$script_basename"
        return 1
    fi

    check_docker_available
    log INFO "Running $script_basename inside container '$container_name' using image '$image_tag'"
    "$DOCKER_BIN" run --rm \
        --name "$container_name" \
        -v "$abs_task_dir":/workspace \
        -w /workspace \
        "$image_tag" \
        Rscript "$script_basename"
}

usage() {
    cat <<'USAGE'
Docker utility helper

Commands:
  check                Ensure Docker daemon is reachable
  build [TAG]          Build the R runner image (default tag: codex-r-runner:latest)
  run SCRIPT TASK_DIR [IMAGE] [CONTAINER]
                       Run the provided script inside the Docker image using the task directory mount
USAGE
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-}"
    case "$cmd" in
        check)
            check_docker_available
            ;;
        build)
            shift
            build_r_image "${1:-}"
            ;;
        run)
            shift
            run_r_in_container "$@"
            ;;
        -h|--help|help|'')
            usage
            ;;
        *)
            log ERROR "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
fi
