# ci-workflows

Shared GitHub Actions infrastructure for iOS apps. The headline piece is a
**reusable TestFlight → Linear → Claude triage workflow** so each new app
needs only ~15 lines of caller YAML instead of the ~230-line monolith.

## Layout

```text
.github/workflows/triage-testflight.yml    reusable workflow (workflow_call)
prompts/triage.md                          templated triage prompt
bootstrap/bootstrap-feedback.sh            per-app wiring CLI
bootstrap/caller-workflow.template.yml     caller workflow template
```

## What the pipeline does

1. Hourly cron pulls TestFlight feedback + crashes from App Store Connect.
2. Creates a Linear issue per item (idempotent via `attachmentsForURL`).
3. Finds untriaged TF tickets (state=Triage, priority=None,
   title prefix `[TestFlight`).
4. Hands them to `anthropics/claude-code-action@v1` which runs the prompt
   in `prompts/triage.md` against the Linear MCP server. The action
   authenticates via `CLAUDE_CODE_OAUTH_TOKEN` so usage bills against the
   Claude Max subscription, not API credits, and bypasses the routine
   15/day cap.

## Onboarding a new app (~30 seconds)

```bash
cd /path/to/new-ios-app
/path/to/ci-workflows/bootstrap/bootstrap-feedback.sh \
  --app-name "Mathom" \
  --bundle-id "cafe.rpc.Mathom" \
  --ticket-prefix "MTM" \
  --linear-project "Mathom" \
  --app-module "Mathom"
```

The script:

- Sources shared secrets from `~/.config/feedback-pipeline.env` if it
  exists; otherwise prompts.
- Verifies the Linear project exists.
- Pushes all required GitHub secrets via `gh secret set`.
- Writes `.github/workflows/triage-testflight.yml` in the current repo
  (the caller — uses `maxdubrinsky/ci-workflows/.github/workflows/triage-testflight.yml@main`).

Commit and push the new workflow file, then optionally trigger a dry run:

```bash
gh workflow run triage-testflight.yml --field dry_run=true
```

## Shared secrets file format

`~/.config/feedback-pipeline.env`:

```bash
LINEAR_API_TOKEN=lin_api_...
LINEAR_TEAM_ID=<uuid>
CLAUDE_CODE_OAUTH_TOKEN=<from `claude setup-token` on logged-in box>
```

These are the same across every app. Per-app TestFlight secrets are
always prompted (different ASC API keys per app).

## Migrating an existing app

For apps that already have `testflight-pm.yml` or similar:

1. Run the bootstrap script — it writes a new file at
   `.github/workflows/triage-testflight.yml` (backed up if it exists).
2. Delete the old workflow file (e.g. `testflight-pm.yml`) in the same
   commit.
3. Tear down the Anthropic routine — it is no longer fired.
4. Optionally remove the now-unused `TRIAGE_ROUTINE_URL` and
   `TRIAGE_ROUTINE_TOKEN` repo secrets.

## Tuning the prompt

`prompts/triage.md` is templated with `{{app_name}}`, `{{ticket_prefix}}`,
`{{linear_project}}`, `{{linear_team_id}}`, `{{app_module}}`. The
reusable workflow substitutes these before passing the prompt to Claude
Code. Rule-of-thumb edits — category criteria, priority defaults,
duplicate-matching strictness — go in this file; per-app values live in
the caller's `with:` block.

To pin a caller workflow to a specific prompt revision, set
`ci_workflows_ref` on the caller:

```yaml
with:
  ci_workflows_ref: "v1.2.0"
  # ...
```

## Caveats / things to verify

- The reusable workflow expects this repo to be reachable to the caller.
  If you make this repo private, the caller repos need read access via
  GitHub Actions settings (`Settings → Actions → General → Access`).
- The `anthropics/claude-code-action@v1` MCP config uses the
  `linear-mcp-server` npm package. Adjust if you use a different Linear
  MCP implementation.
- `claude setup-token` generates an OAuth token tied to your account.
  Treat it as sensitive — rotate via `claude setup-token` again if
  leaked.
