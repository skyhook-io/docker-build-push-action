#!/usr/bin/env bash
#
# Resolve Docker build context + Dockerfile from `.skyhook/skyhook.yaml`.
#
# Resolution order (mirrors koala-backend's SkyhookConfig.ResolveBuildContext):
#   per-service buildTool.docker.<field>  ->
#   root        buildTool.docker.<field>  ->
#   <empty>  (consumer's `||` falls through to inputs.context / inputs.dockerfile)
#
# Field names: prefer canonical `buildContext`; fall back to legacy
# `contextPath` for back-compat (with a deprecation warning). `dockerfilePath`
# has no historical alias.
#
# We never preset `resolved_context=code` — that previously clobbered any
# value the calling workflow had already resolved for `inputs.context`.
# When skyhook.yaml provides nothing, we emit nothing and let inputs win.
#
# Inputs (env vars):
#   SERVICE_NAME    Service name to look up. If empty, the script is a no-op.
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
: "${REPO_PREFIX:=code}"
: "${SKYHOOK_FILE:=.skyhook/skyhook.yaml}"

# Direct emitted output to GHA's $GITHUB_OUTPUT when present, else stdout.
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

if [[ -z "$SERVICE_NAME" ]]; then
  log "No service_name provided; skipping skyhook config resolution"
  exit 0
fi

if [[ ! -f "$SKYHOOK_FILE" ]]; then
  log "::warning::service_name '$SERVICE_NAME' was provided but $SKYHOOK_FILE was not found. Using inputs.context / inputs.dockerfile as-is."
  exit 0
fi

log "Found config file: $SKYHOOK_FILE"

# Service must exist in the config; otherwise we don't second-guess the inputs.
SERVICE_EXISTS=$(yq '(.services // []) | map(select(.name == strenv(SERVICE_NAME))) | .[0].name // ""' "$SKYHOOK_FILE" 2>/dev/null || true)
[[ "$SERVICE_EXISTS" == "null" ]] && SERVICE_EXISTS=""
if [[ -z "$SERVICE_EXISTS" ]]; then
  log "::warning::Service '$SERVICE_NAME' not found in $SKYHOOK_FILE. Using inputs.context / inputs.dockerfile as-is."
  exit 0
fi
log "Found service '$SERVICE_NAME' in config"

SVC_CTX=$(yq_get '(.services // []) | map(select(.name == strenv(SERVICE_NAME))) | (.[0].buildTool.docker.buildContext // "")' "$SKYHOOK_FILE")
SVC_CTX_LEGACY=$(yq_get '(.services // []) | map(select(.name == strenv(SERVICE_NAME))) | (.[0].buildTool.docker.contextPath // "")' "$SKYHOOK_FILE")
SVC_DFP=$(yq_get '(.services // []) | map(select(.name == strenv(SERVICE_NAME))) | (.[0].buildTool.docker.dockerfilePath // "")' "$SKYHOOK_FILE")

ROOT_CTX=$(yq_get '.buildTool.docker.buildContext // ""' "$SKYHOOK_FILE")
ROOT_CTX_LEGACY=$(yq_get '.buildTool.docker.contextPath // ""' "$SKYHOOK_FILE")
ROOT_DFP=$(yq_get '.buildTool.docker.dockerfilePath // ""' "$SKYHOOK_FILE")

# One deprecation warning if anyone is still on `contextPath` and would
# actually be picked up after the canonical `buildContext` lookup misses.
if { [[ -z "$SVC_CTX" && -n "$SVC_CTX_LEGACY" ]] || [[ -z "$SVC_CTX" && -z "$ROOT_CTX" && -n "$ROOT_CTX_LEGACY" ]]; }; then
  log "::warning::buildTool.docker.contextPath is deprecated; rename to buildContext (see https://github.com/skyhook-io/docker-build-push-action#skyhook-config)."
fi

# Apply resolution order: service > root > empty.
CTX="${SVC_CTX:-${SVC_CTX_LEGACY:-${ROOT_CTX:-$ROOT_CTX_LEGACY}}}"
DFP="${SVC_DFP:-$ROOT_DFP}"

if [[ -n "$CTX" ]]; then
  RESOLVED_CONTEXT="$REPO_PREFIX/$CTX"
  # When context is overridden but no Dockerfile is specified anywhere,
  # default the Dockerfile to <context>/Dockerfile (same as Docker's
  # built-in default, but anchored to the resolved context).
  if [[ -z "$DFP" ]]; then
    DFP="$CTX/Dockerfile"
    log "Defaulting dockerfile to: $REPO_PREFIX/$DFP"
  fi
  log "Using context: $RESOLVED_CONTEXT"
  emit "resolved_context=$RESOLVED_CONTEXT"
else
  log "No buildContext override in skyhook.yaml; deferring to inputs.context"
fi

if [[ -n "$DFP" ]]; then
  RESOLVED_DOCKERFILE="$REPO_PREFIX/$DFP"
  log "Using dockerfile: $RESOLVED_DOCKERFILE"
  emit "resolved_dockerfile=$RESOLVED_DOCKERFILE"
else
  log "No dockerfilePath override in skyhook.yaml; deferring to inputs.dockerfile"
fi

emit "config_file=$SKYHOOK_FILE"
emit "service_name=$SERVICE_NAME"
