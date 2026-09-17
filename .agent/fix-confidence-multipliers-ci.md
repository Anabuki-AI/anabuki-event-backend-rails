# CI failure investigation: confidence multipliers

- Date: 2026-09-18
- Branch/worktree: `fix-confidence-multipliers-ci` / `backend/.worktree/fix-confidence-multipliers-ci`
- Base: `origin/main` at `095b9606681f6c5ee753cd207a9b370ea5a441d0` (backend deployment PR #36 merge)
- Scope: backend test expectation only; no Cloudflare deployment files or credentials changed.

## Observed CI failure

- Workflow: `35246095008` (`https://github.com/Anabuki-AI/anabuki-event-backend-rails/actions/runs/35246095008`)
- Failed job: `check` / job `105286567134`
- Failed example: `spec/requests/participant_quiz_state_spec.rb:59`, answering state response
- Result: `198 examples, 1 failure`, exit code `1`.
- `gh run view --job 105286567134 --log-failed` showed the response had the additional key:
  `confidence_multipliers => { "high" => 2.0, "low" => 0.5, "normal" => 1.0 }`.
- All earlier CI steps (security scan, lint, Zeitwerk) passed; deployment was skipped because `check` failed.

## Contract/implementation investigation

- `app/controllers/participant_quiz_controller.rb`, `ParticipantQuizController#participant_quiz_state` adds `confidence_multipliers` for every in-progress participant state.
- `ConfidenceMultiplier.all_levels` initializes missing defaults without overwriting configured values and returns the supported levels.
- `app/models/confidence_multiplier.rb` defines defaults high `2.00`, normal `1.00`, low `0.50` and validates the supported range.
- Backend PR #35 (`https://github.com/Anabuki-AI/anabuki-event-backend-rails/pull/35`) was merged into main before PR #36 specifically to expose operator-configured, read-only confidence multipliers to participants.
- The participant UI contract documents that multiplier values are participant-visible configuration, so this response key is intentional API behavior, not a production regression.

## Change

Added the exact `confidence_multipliers` map to the existing strict response expectation in `spec/requests/participant_quiz_state_spec.rb`. No implementation change was made.

## Verification plan

- Run the failed example and related participant quiz request/model specs with PostgreSQL available.
- Run full RSpec if feasible, RuboCop, and `git diff --check`.
- Record command exit codes and counts in the final report.

## Verification results

The host Ruby executable was unavailable (`ruby` not found; the WindowsApps `bundle` shim exited 127), so verification used a Docker image built from this worktree (`fix-confidence-multipliers-ci-test`). The existing local PostgreSQL container was reused on host port 5433; only the two local test databases were recreated.

- Targeted participant state/answers/model specs: exit `0`, `18 examples, 0 failures`.
- Fresh full suite after recreating test databases: exit `0`, `198 examples, 0 failures`.
- `bundle exec rubocop --cache false`: exit `0`, `136 files inspected, no offenses`.
- `bundle exec rails zeitwerk:check`: exit `0`, application eager load passed.
- `bundle exec brakeman --no-pager`: exit `0`, `19 controllers, 17 models, 1 template, 0 warnings`.
- `git diff --check`: exit `0`.

An initial full-suite attempt against a reused test database reported 12 data-contamination failures; this was not a code failure. Recreating only the local Rails test database and rerunning produced the clean result above.
