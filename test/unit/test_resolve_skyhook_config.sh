#!/usr/bin/env bash
#
# Unit tests for scripts/resolve_skyhook_config.sh.
#
# Each case sets env vars for the resolver, runs it against a fixture YAML in
# fixtures/, and asserts the contents written to a fake $GITHUB_OUTPUT.
#
# Run from anywhere:
#   bash test/unit/test_resolve_skyhook_config.sh
#
# Requires `yq v4` on PATH (same requirement as the action itself).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESOLVER="$REPO_ROOT/scripts/resolve_skyhook_config.sh"
FIXTURES="$REPO_ROOT/test/unit/fixtures"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

[[ -x "$RESOLVER" ]] || chmod +x "$RESOLVER"

if ! command -v yq >/dev/null; then
  echo "yq is required" >&2
  exit 2
fi
if ! yq --version 2>&1 | grep -q 'version v4'; then
  echo "yq v4 is required, found: $(yq --version 2>&1)" >&2
  exit 2
fi

pass=0; fail=0

# run_case <name> <fixture> <SERVICE_NAME> <expected_outputs> [expected_stderr_pattern]
#
# expected_outputs is a `;`-separated list of grep-E patterns that must each
# match a line in $GITHUB_OUTPUT. Prefix a pattern with `!` to assert it MUST
# NOT match. expected_stderr_pattern, if non-empty, must match somewhere in
# the resolver's stderr (used to assert that errors/warnings actually surface
# to the job log instead of being silently swallowed).
run_case() {
  local name=$1 fixture=$2 svc=$3 expects=$4 expect_stderr=${5:-}
  local case_dir out_file
  case_dir="$TMPROOT/$name"
  mkdir -p "$case_dir"
  out_file="$case_dir/github_output"
  : > "$out_file"

  SERVICE_NAME="$svc" \
  REPO_PREFIX="code" \
  SKYHOOK_FILE="$FIXTURES/$fixture" \
  GITHUB_OUTPUT="$out_file" \
    bash "$RESOLVER" >"$case_dir/stdout" 2>"$case_dir/stderr"

  local ok=1
  local IFS=';'
  for pattern in $expects; do
    pattern="${pattern# }"; pattern="${pattern% }"
    [[ -z "$pattern" ]] && continue
    if [[ "${pattern:0:1}" == "!" ]]; then
      local p="${pattern:1}"
      if grep -Eq "$p" "$out_file"; then
        printf '  FAIL  %s: unexpected output line matching /%s/\n' "$name" "$p"
        ok=0
      fi
    else
      if ! grep -Eq "$pattern" "$out_file"; then
        printf '  FAIL  %s: missing output line matching /%s/\n' "$name" "$pattern"
        ok=0
      fi
    fi
  done
  unset IFS

  if [[ -n "$expect_stderr" ]] && ! grep -Eq "$expect_stderr" "$case_dir/stderr"; then
    printf '  FAIL  %s: missing stderr line matching /%s/\n' "$name" "$expect_stderr"
    ok=0
  fi

  if [[ "$ok" == "1" ]]; then
    printf '  ok    %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  ---- $GITHUB_OUTPUT ----\n'
    sed 's/^/    /' "$out_file"
    printf '  ---- stderr ----\n'
    sed 's/^/    /' "$case_dir/stderr"
    fail=$((fail + 1))
  fi
}

echo "running unit tests against $RESOLVER"

# ── Per-service overrides ──────────────────────────────────────────────────

# 1. Canonical buildContext + dockerfilePath, both per-service.
run_case "canonical-fields-emitted" \
  "canonical-only.yaml" "web" \
  "^resolved_context=code/apps/web/src$ ; ^resolved_dockerfile=code/apps/web/docker/Dockerfile$"

# 2. Legacy contextPath honored (back-compat path). When dockerfilePath is
#    unset, dockerfile falls back to <service.path>/Dockerfile (NOT to
#    <context>/Dockerfile; context and dockerfile chains are independent).
run_case "legacy-contextpath-honored" \
  "legacy-contextpath.yaml" "legacy" \
  "^resolved_context=code/apps/legacy$ ; ^resolved_dockerfile=code/apps/legacy/Dockerfile$"

# 3. Per-service value overrides root.
run_case "service-overrides-root" \
  "root-and-services.yaml" "web" \
  "^resolved_context=code/apps/web/src$ ; !^resolved_context=code/shared$"

# 4. Service with no per-service buildTool inherits root buildContext / dockerfilePath.
run_case "service-inherits-root" \
  "root-and-services.yaml" "api" \
  "^resolved_context=code/shared$ ; ^resolved_dockerfile=code/shared/Dockerfile$"

# ── Fallback chain (no YAML override) ──────────────────────────────────────

# 5. No buildTool anywhere, but service has `path` in YAML → context=code,
#    dockerfile=code/<path>/Dockerfile.
run_case "no-override-with-service-path" \
  "no-buildtool-anywhere.yaml" "bare-with-path" \
  "^resolved_context=code$ ; ^resolved_dockerfile=code/apps/bare/Dockerfile$"

# 6. No buildTool AND no service.path in YAML → context=code, dockerfile=code/Dockerfile.
run_case "no-override-no-service-path" \
  "no-buildtool-anywhere.yaml" "bare-no-path" \
  "^resolved_context=code$ ; ^resolved_dockerfile=code/Dockerfile$"

# 7. `./` is normalized to "no override" — context falls through to default.
#    (dockerfilePath in the fixture is explicitly set, so dockerfile uses that.)
run_case "dotslash-context-is-normalized" \
  "dotslash-context.yaml" "monorepo-root" \
  "^resolved_context=code$ ; ^resolved_dockerfile=code/apps/foo/Dockerfile$"

# ── No-op edge cases ───────────────────────────────────────────────────────

# 8. Empty service_name → manual mode, no outputs at all.
run_case "no-service-name-is-noop" \
  "canonical-only.yaml" "" \
  "!^resolved_context= ; !^resolved_dockerfile= ; !^config_file= ; !^service_name="

# 9. Service not found in YAML → root-level overrides (none in this fixture)
#    apply, no service.path is available, so dockerfile falls all the way
#    through to code/Dockerfile. Diagnostic warning emitted (not asserted here).
run_case "unknown-service-uses-defaults" \
  "canonical-only.yaml" "does-not-exist" \
  "^resolved_context=code$ ; ^resolved_dockerfile=code/Dockerfile$ ; ^service_name=does-not-exist$"

# 10. Malformed YAML must surface yq's parse error to stderr (i.e. to the GHA
#     job log) instead of being silently swallowed. The resolver still falls
#     through to defaults so the build can proceed — the contract is "noisy
#     fallback", not "fail closed".
run_case "malformed-yaml-surfaces-error" \
  "malformed.yaml" "any" \
  "^resolved_context=code$ ; ^resolved_dockerfile=code/Dockerfile$" \
  "Error|error"

# ── Docs-vs-code consistency ───────────────────────────────────────────────

# 11. The resolver's deprecation warning links to a `#skyhook-config` anchor
#     in README.md. Make sure that anchor still exists — silent-rotting docs
#     turn the warning into a 404 for every user hitting the legacy field.
readme_anchor_check() {
  local readme="$REPO_ROOT/README.md"
  local script="$RESOLVER"
  local linked_anchor heading_slug
  linked_anchor=$(grep -oE '#skyhook-config[^ )]*' "$script" | head -n1 || true)
  if [[ -z "$linked_anchor" ]]; then
    printf '  ok    readme-anchor-for-deprecation-warning (no anchor referenced)\n'
    pass=$((pass + 1))
    return
  fi
  # GitHub turns "## Skyhook Config" into anchor "#skyhook-config".
  if grep -qE '^## +Skyhook Config *$' "$readme"; then
    printf '  ok    readme-anchor-for-deprecation-warning\n'
    pass=$((pass + 1))
  else
    printf '  FAIL  readme-anchor-for-deprecation-warning: %s referenced from resolver but no matching `## Skyhook Config` heading in README.md\n' "$linked_anchor"
    fail=$((fail + 1))
  fi
}
readme_anchor_check

echo
if [[ "$fail" -eq 0 ]]; then
  echo "ALL $pass UNIT TESTS PASSED"
  exit 0
else
  echo "$fail/$((pass+fail)) UNIT TESTS FAILED"
  exit 1
fi
