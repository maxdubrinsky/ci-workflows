#!/usr/bin/env bash
# bootstrap-feedback.sh — wire up the TestFlight → Linear → Claude triage
# pipeline for an iOS app repo. Idempotent: re-running is safe.
#
# Usage:
#   bootstrap-feedback.sh \
#     --app-name Mathom \
#     --bundle-id cafe.rpc.Mathom \
#     --ticket-prefix MTM \
#     --linear-project "Mathom" \
#     --app-module Mathom \
#     [--repo-dir /path/to/repo]   # defaults to $PWD
#
# Per-app secrets prompted interactively (or sourced from env):
#   TESTFLIGHT_KEY_ID, TESTFLIGHT_ISSUER_ID, TESTFLIGHT_PRIVATE_KEY_B64
#
# Shared secrets sourced from ~/.config/feedback-pipeline.env (key=value lines)
# if present; otherwise prompted:
#   LINEAR_API_TOKEN, LINEAR_TEAM_ID, CLAUDE_CODE_OAUTH_TOKEN

set -euo pipefail

# ── arg parsing ───────────────────────────────────────────────────────────

APP_NAME=""
BUNDLE_ID=""
TICKET_PREFIX=""
LINEAR_PROJECT=""
APP_MODULE=""
REPO_DIR="$PWD"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)       APP_NAME="$2";       shift 2 ;;
    --bundle-id)      BUNDLE_ID="$2";      shift 2 ;;
    --ticket-prefix)  TICKET_PREFIX="$2";  shift 2 ;;
    --linear-project) LINEAR_PROJECT="$2"; shift 2 ;;
    --app-module)     APP_MODULE="$2";     shift 2 ;;
    --repo-dir)       REPO_DIR="$2";       shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

for v in APP_NAME BUNDLE_ID TICKET_PREFIX LINEAR_PROJECT APP_MODULE; do
  if [[ -z "${!v}" ]]; then
    flag="${v,,}"
    flag="${flag//_/-}"
    echo "::error:: --${flag} is required" >&2
    exit 2
  fi
done

# ── sanity checks ─────────────────────────────────────────────────────────

command -v gh >/dev/null || { echo "::error:: gh CLI required" >&2; exit 1; }
command -v jq >/dev/null || { echo "::error:: jq required" >&2; exit 1; }

cd "$REPO_DIR"
[[ -d .git ]] || { echo "::error:: $REPO_DIR is not a git repo" >&2; exit 1; }

REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
  echo "::error:: no gh remote — run 'gh repo create' first or set origin"; exit 1;
}
echo "→ Repo: $REPO_SLUG"
echo "→ App:  $APP_NAME ($BUNDLE_ID) — module=$APP_MODULE, prefix=$TICKET_PREFIX, project=$LINEAR_PROJECT"

# ── shared secrets ────────────────────────────────────────────────────────

SHARED_ENV="${HOME}/.config/feedback-pipeline.env"
if [[ -f "$SHARED_ENV" ]]; then
  echo "→ Sourcing shared secrets from $SHARED_ENV"
  set -a; . "$SHARED_ENV"; set +a
fi

prompt_secret() {
  local var="$1" desc="$2"
  if [[ -n "${!var:-}" ]]; then return 0; fi
  printf '  %s (%s): ' "$var" "$desc" >&2
  read -rs val; echo >&2
  printf -v "$var" '%s' "$val"
  export "$var"
}

echo "→ Shared secrets (Linear + Claude Code OAuth):"
prompt_secret LINEAR_API_TOKEN      "Linear personal API key, lin_api_…"
prompt_secret LINEAR_TEAM_ID        "Linear team UUID"
prompt_secret CLAUDE_CODE_OAUTH_TOKEN "from 'claude setup-token' on logged-in box"

echo "→ Per-app TestFlight secrets:"
prompt_secret TESTFLIGHT_KEY_ID         "ASC API key ID, ~10 chars"
prompt_secret TESTFLIGHT_ISSUER_ID      "ASC issuer UUID"
prompt_secret TESTFLIGHT_PRIVATE_KEY_B64 "base64 of the .p8 file contents"

# Bundle ID is captured from CLI but stored as a secret to match the existing pattern.
export TESTFLIGHT_BUNDLE_ID="$BUNDLE_ID"

# ── verify Linear project exists ──────────────────────────────────────────

echo "→ Verifying Linear project '$LINEAR_PROJECT' exists…"
proj_exists=$(curl -fsS -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg p "$LINEAR_PROJECT" \
    '{query:"query($p:String!){projects(filter:{name:{eq:$p}},first:1){nodes{id name}}}",variables:{p:$p}}')" \
  | jq -r '.data.projects.nodes | length')

if [[ "$proj_exists" == "0" ]]; then
  echo "::warning:: Linear project '$LINEAR_PROJECT' not found. Create it in Linear before running the workflow."
fi

# ── push secrets to repo ──────────────────────────────────────────────────

set_secret() {
  local name="$1" val="$2"
  if gh secret list --json name -q '.[].name' | grep -qx "$name"; then
    echo "    $name: already set, overwriting"
  fi
  gh secret set "$name" --body "$val" >/dev/null
}

echo "→ Pushing GitHub secrets to $REPO_SLUG…"
set_secret LINEAR_API_TOKEN            "$LINEAR_API_TOKEN"
set_secret LINEAR_TEAM_ID              "$LINEAR_TEAM_ID"
set_secret CLAUDE_CODE_OAUTH_TOKEN     "$CLAUDE_CODE_OAUTH_TOKEN"
set_secret TESTFLIGHT_KEY_ID           "$TESTFLIGHT_KEY_ID"
set_secret TESTFLIGHT_ISSUER_ID        "$TESTFLIGHT_ISSUER_ID"
set_secret TESTFLIGHT_PRIVATE_KEY_B64  "$TESTFLIGHT_PRIVATE_KEY_B64"
set_secret TESTFLIGHT_BUNDLE_ID        "$TESTFLIGHT_BUNDLE_ID"

# ── write caller workflow ─────────────────────────────────────────────────

TEMPLATE_PATH="$(dirname "$(readlink -f "$0")")/caller-workflow.template.yml"
[[ -f "$TEMPLATE_PATH" ]] || { echo "::error:: template missing: $TEMPLATE_PATH" >&2; exit 1; }

OUT=".github/workflows/triage-testflight.yml"
mkdir -p "$(dirname "$OUT")"

if [[ -f "$OUT" ]]; then
  echo "→ $OUT already exists. Backup at ${OUT}.bak"
  cp "$OUT" "${OUT}.bak"
fi

sed \
  -e "s|__APP_NAME__|${APP_NAME}|g" \
  -e "s|__LINEAR_PROJECT__|${LINEAR_PROJECT}|g" \
  -e "s|__TICKET_PREFIX__|${TICKET_PREFIX}|g" \
  -e "s|__APP_MODULE__|${APP_MODULE}|g" \
  "$TEMPLATE_PATH" > "$OUT"

echo "→ Wrote $OUT"
echo
echo "── Done ──"
echo "  Commit and push the new workflow file:"
echo "    git add $OUT && git commit -m 'Wire up TestFlight triage pipeline' && git push"
echo
echo "  First run (after push) — trigger manually:"
echo "    gh workflow run triage-testflight.yml --field dry_run=true"
echo
if [[ "$proj_exists" == "0" ]]; then
  echo "  ⚠ Remember to create the '$LINEAR_PROJECT' Linear project before the first non-dry run."
fi
