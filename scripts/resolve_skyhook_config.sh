#!/usr/bin/env bash
#
# Resolve Docker build context + Dockerfile from `.skyhook/skyhook.yaml`.
#
# Resolution chain (mirrors koala-backend/.../build_image.yml — PR #1319):
#
#   step │ context                   │ dockerfile
#   ─────┼───────────────────────────┼──────────────────────────────────
#    1   │ per-service buildContext  │ per-service dockerfilePath
#    2   │ root        buildContext  │ root        dockerfilePath
#    3   │ code                      │ code/<SERVICE_DIR>/Dockerfile
#    4   │ code                      │ code/Dockerfile   (no SERVICE_DIR)
#
# YAML values are repo-root-relative ("absolute from repo root"); the script
# only ever prepends `$REPO_PREFIX` (the calling workflow's checkout dir).
#
# Field names: prefer canonical `buildContext`; fall back to legacy
# `contextPath` for back-compat (with a deprecation warning). `dockerfilePath`
# has no historical alias.
#
# Inputs (env vars):
#   SERVICE_NAME    Service name to look up. If empty, the script is a no-op
#                   (manual mode — caller's `inputs.context` / `inputs.dockerfile`
#                   are used as-is).
#   SERVICE_DIR     Service directory inside the repo (typically the same as
#                   skyhook.yaml's `services[].path`). Optional; only affects
#                   the dockerfile fallback (step 3 above).
#   REPO_PREFIX     Path the consumer expects values to live under (default: "code").
#   SKYHOOK_FILE    Optional override for the config file path
#                   (default: "$PWD/.skyhook/skyhook.yaml").
#   GITHUB_OUTPUT   File to append `key=value` outputs to (GHA-compatible).
#                   If unset, outputs go to stdout instead.
#
# Requires `yq v4` (Mike Farah's Go yq) on PATH. `strenv()` is yq v4's env-var
# injection primitive — the jq-style `--arg` flag is NOT supported on yq v4
# and silently produces wrong queries.

set -euo pipefail

: "${SERVICE_NAME:=}"
: "${SERVICE_DIR:=}"
: "${REPO_PREFIX:=code}"
: "${SKYHOOK_FILE:=.skyhook/skyhook.yaml}"

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
  else
    printf '%s\n' "$1"
  fi
}

log() { printf '%s\n' "$*" >&2; }

# yq_get <query> <file> — returns "" for missing/null and normalizes "."/"./".
yq_get() {
  local q=$1 file=$2 out
  out=$(yq "$q" "$file" 2>/dev/null || true)
  # yq emits the literal string "null" when a path resolves to a missing key
  # and `// ""` did not absorb it (e.g. when a parent path is itself absent).
  [[ "$out" == "null" ]] && out=""
  # Treat "." and "./" as "no override": both `koala-backend` (canonical
  # resolver) and the workflow-side resolver in `build_image.yml` collapse
  # them. Keeping the same semantic here so all three layers agree.
  case "$out" in .|./) out="" ;; esac
  # Strip a leading `./` so we emit `code/src` instead of `code/./src`.
  out=${out#./}
  printf '%s' "$out"
}

# Manual mode: nothing to resolve, leave inputs alone.
if [[ -z "$SERVICE_NAME" ]]; then
  log "No service_name provided; skipping skyhook config resolution"
  exit 0
fi

# Pull root-level overrides up front: they apply even when no per-service
# config (or no service entry) exists.
ROOT_CTX=""
ROOT_CTX_LEGACY=""
ROOT_DFP=""
SVC_CTX=""
SVC_CTX_LEGACY=""
SVC_DFP=""
CONFIG_PRESENT=0

if [[ -f "$SKYHOOK_FILE" ]]; then
  CONFIG_PRESENT=1
  log "Found config file: $SKYHOOK_FILE"

  ROOT_CTX=$(yq_get '.buildTool.docker.buildContext // ""' "$SKYHOOK_FILE")
  ROOT_CTX_LEGACY=$(yq_get '.buildTool.docker.contextPath // ""' "$SKYHOOK_FILE")
  ROOT_DFP=$(yq_get '.buildTool.docker.dockerfilePath // ""' "$SKYHOOK_FILE")

  SERVICE_EXISTS=$(yq '(.services // []) | map(select(.name == strenv(SERVICE_NAME))) | .[0].name // ""' "$SKYHOOK_FILE" 2>/dev/null || true)
  [[ "$SERVICE_EXISTS" == "null" ]] && SERVICE_EXISTS=""
  if [[ -n "$SERVICE_EXISTS" ]]; then
    log "Found service '$SERVICE_NAME' in config"
    SVC_CTX=$(yq_get '(.services // []) | map(select(.name == strenv(SERVICE_NAME))) | (.[0].buildTool.docker.buildContext // "")' "$SKYHOOK_FILE")
    SVC_CTX_LEGACY=$(yq_get '(.services // []) | map(select(.name == strenv(SERVICE_NAME))) | (.[0].buildTool.docker.contextPath // "")' "$SKYHOOK_FILE")
    SVC_DFP=$(yq_get '(.services // []) | map(select(.name == strenv(SERVICE_NAME))) | (.[0].buildTool.docker.dockerfilePath // "")' "$SKYHOOK_FILE")
  else
    log "::warning::Service '$SERVICE_NAME' not found in $SKYHOOK_FILE; only root-level overrides (if any) will apply."
  fi
else
  log "::warning::service_name '$SERVICE_NAME' was provided but $SKYHOOK_FILE was not found; using SERVICE_DIR / code defaults."
fi

# One-shot deprecation warning if anyone is still on `contextPath` AND the
# canonical name didn't already win at the same scope.
if { [[ -z "$SVC_CTX" && -n "$SVC_CTX_LEGACY" ]] || [[ -z "$SVC_CTX" && -z "$ROOT_CTX" && -n "$ROOT_CTX_LEGACY" ]]; }; then
  log "::warning::buildTool.docker.contextPath is deprecated; rename to buildContext (see https://github.com/skyhook-io/docker-build-push-action#skyhook-config)."
fi

# ── Context chain ───────────────────────────────────────────────────────────
# per-service > root > "code" (no SERVICE_DIR step on context — the build
# context defaults to the entire checkout, and `.dockerignore` / Dockerfile
# COPY paths govern what's actually included).
CTX="${SVC_CTX:-${SVC_CTX_LEGACY:-${ROOT_CTX:-$ROOT_CTX_LEGACY}}}"
if [[ -n "$CTX" ]]; then
  RESOLVED_CONTEXT="$REPO_PREFIX/$CTX"
else
  RESOLVED_CONTEXT="$REPO_PREFIX"
fi
log "Using context: $RESOLVED_CONTEXT"
emit "resolved_context=$RESOLVED_CONTEXT"

# ── Dockerfile chain ────────────────────────────────────────────────────────
# per-service > root > <SERVICE_DIR>/Dockerfile > Dockerfile.
DFP="${SVC_DFP:-$ROOT_DFP}"
if [[ -n "$DFP" ]]; then
  RESOLVED_DOCKERFILE="$REPO_PREFIX/$DFP"
elif [[ -n "$SERVICE_DIR" ]]; then
  RESOLVED_DOCKERFILE="$REPO_PREFIX/$SERVICE_DIR/Dockerfile"
else
  RESOLVED_DOCKERFILE="$REPO_PREFIX/Dockerfile"
fi
log "Using dockerfile: $RESOLVED_DOCKERFILE"
emit "resolved_dockerfile=$RESOLVED_DOCKERFILE"

# Diagnostic outputs (consumed by the action's step summary).
if [[ "$CONFIG_PRESENT" == "1" ]]; then
  emit "config_file=$SKYHOOK_FILE"
fi
emit "service_name=$SERVICE_NAME"
