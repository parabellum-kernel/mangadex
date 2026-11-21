#!/usr/bin/env bash
# =============================================================================
# MangaDex Pipeline Execution Script
# Orchestrates build, pre-flight verification, permissions, and execution
# of Parabellum pipelines for MangaDex.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Auto-source .env if present (prefer root .env over configs/.env)
ENV_FILE=""
for candidate in "configs/.env" ".env"; do
    if [[ -f "$candidate" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$candidate"
        set +a
        ENV_FILE="$candidate"
    fi
done

PIPELINE_PATH="configs/pipeline.yaml"
MODE="run"
DO_BUILD=false
EXTRA_ARGS=()

usage() {
    cat <<EOF
Usage: ./run_pipeline.sh [options] [-- <extra_args>]

Options:
  -p, --pipeline <path>   Path to pipeline YAML (default: configs/pipeline.yaml)
  -v, --validate          Run pre-flight validation only (do not execute)
  -b, --build             Force rebuild of binary and shared plugin library
  -s, --serve             Start pipeline in server/daemon mode
  -h, --help              Show this help message

Examples:
  ./run_pipeline.sh                        # Validate and run default pipeline
  ./run_pipeline.sh --validate             # Check syntax, DAG, and plugins
  ./run_pipeline.sh -p configs/custom.yaml # Run custom pipeline
EOF
    exit 0
}

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--pipeline)
            PIPELINE_PATH="$2"
            shift 2
            ;;
        -v|--validate)
            MODE="validate"
            shift
            ;;
        -b|--build)
            DO_BUILD=true
            shift
            ;;
        -s|--serve)
            MODE="serve"
            shift
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            EXTRA_ARGS+=("$@")
            break
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

ENGINE_BIN="${PARABELLUM_ENGINE_BIN:-$SCRIPT_DIR/../engine/zig-out/bin/parabellum-engine}"
LIB_DIR="$SCRIPT_DIR/zig-out/lib"
PLUGIN_DIR="${PARABELLUM_PLUGIN_DIR:-$LIB_DIR}"

# 1. Build if plugin library is missing or if --build was requested
if [[ "$DO_BUILD" == true || ! -f "$LIB_DIR/libmanga_catalog.so" ]]; then
    echo "==> Building MangaDex plugin library (zig build)..."
    zig build
fi

# 1b. Sync external drivers and extensions (.so) into LIB_DIR
mkdir -p "$LIB_DIR"
shopt -s nullglob
for COMP_DIR in "$SCRIPT_DIR/../driver" "$SCRIPT_DIR/../extension"; do
    if [[ "$DO_BUILD" == true || ! -d "$COMP_DIR/zig-out/lib" ]]; then
        if [[ -d "$COMP_DIR" ]]; then
            echo "==> Building $(basename "$COMP_DIR") (zig build)..."
            (cd "$COMP_DIR" && zig build)
        fi
    fi
    SO_FILES=("$COMP_DIR/zig-out/lib/"*.so)
    if [[ ${#SO_FILES[@]} -gt 0 ]]; then
        cp "${SO_FILES[@]}" "$LIB_DIR/"
    fi
done
shopt -u nullglob

# 2. Ensure output directory structure exists for artifacts, databases, and logs
mkdir -p "$SCRIPT_DIR/output/logs" "$SCRIPT_DIR/output/cbz" "$LIB_DIR"

# 3. Enforce secure permissions on shared libraries (.so) required by Parabellum ABI security policy
if [[ -d "$LIB_DIR" ]]; then
    chmod 755 "$LIB_DIR"/*.so 2>/dev/null || true
fi

# 4. Verify pipeline file and engine binary exist
if [[ ! -f "$PIPELINE_PATH" ]]; then
    echo "Error: Pipeline file '$PIPELINE_PATH' not found." >&2
    exit 1
fi
if [[ ! -x "$ENGINE_BIN" ]]; then
    echo "Error: Engine binary '$ENGINE_BIN' not found. Build it with 'cd ../engine && zig build'." >&2
    exit 1
fi

# 5. Dispatch selected mode
case "$MODE" in
    validate)
        echo "==> Validating pipeline '$PIPELINE_PATH'..."
        exec "$ENGINE_BIN" --plugin-dir "$PLUGIN_DIR" validate "$PIPELINE_PATH" "${EXTRA_ARGS[@]}"
        ;;
    serve)
        echo "==> Starting pipeline server with '$PIPELINE_PATH'..."
        exec "$ENGINE_BIN" --plugin-dir "$PLUGIN_DIR" --serve --pipeline "$PIPELINE_PATH" "${EXTRA_ARGS[@]}"
        ;;
    run)
        echo "==> Validating pre-flight requirements..."
        "$ENGINE_BIN" --plugin-dir "$PLUGIN_DIR" validate "$PIPELINE_PATH"

        echo "==> Executing pipeline '$PIPELINE_PATH'..."
        exec "$ENGINE_BIN" --plugin-dir "$PLUGIN_DIR" run "$PIPELINE_PATH" "${EXTRA_ARGS[@]}"
        ;;
esac
