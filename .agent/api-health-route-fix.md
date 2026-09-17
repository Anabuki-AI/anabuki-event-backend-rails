# API health route fix activity record

- Date: 2026-09-18
- Repository: `Anabuki-AI/anabuki-event-backend-rails`
- Branch: `fix-api-health-route`
- Base after rebase: `origin/main` at `77e00de7d5c37660f809f8d1897ca34a2da1b59c`
- Scope: add the public read-only `GET /api/health` alias while retaining `GET /health` for the container ping endpoint.

## Investigation

- `config/routes.rb` had `GET /health` mapped to `HealthController#show`, but no `/api/health` route.
- `app/controllers/health_controller.rb` already returns JSON `{ status: "ok" }` and has no authentication or mutation.
- `spec/requests/api_contract_spec.rb` covered `/health` but not the frontend-proxied `/api/health` path.
- No frontend source change is included; the frontend `/api/**` proxy can continue unchanged.
- No database, DNS, custom-domain, R2, OAuth, Worker-runtime secret, or production migration operation is part of this change.

## Change

- Added `GET /api/health` to the existing `HealthController#show` action.
- Added a request contract example asserting HTTP 200 and `{ "status": "ok" }` for `/api/health`.
- Kept the existing `/health` route and its request contract unchanged.

## Verification record

Secret values and response headers are intentionally not recorded.

## Local verification after rebase

- `git rebase --autostash origin/main`: exit `0`; rebased onto `77e00de` after the migration-collision PR merged.
- `git diff --check`: exit `0`.
- `actionlint .github/workflows/ci.yml .github/workflows/production-migration.yml`: exit `0`.
- Docker image build from this worktree: exit `0` (`anabuki-health-check-backend:local`).
- Isolated PostgreSQL `db:prepare`: exit `0`; all 22 migrations applied with unique versions.
- `bundle exec rails routes`: exit `0`; both `GET /health` and `GET /api/health` map to `health#show`.
- `RAILS_ENV=test bundle exec rails zeitwerk:check`: exit `0`; `All is good!`.
- Dockerized RSpec: exit `0`; 227 examples, 0 failures.
- `bundle exec rubocop -f simple`: exit `0`; 148 files inspected, no offenses.
- `bundle exec brakeman --no-pager -q`: exit `0`; 0 errors, 0 security warnings.

No database, DNS, custom-domain, R2, OAuth, Worker-runtime secret, or production migration operation is part of this route change.
