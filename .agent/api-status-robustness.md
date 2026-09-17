# API status robustness (P1)

## Findings

- `AdminApiStatusTransport#request` now requires `openssl` and translates `OpenSSL::SSL::SSLError` into its existing `AdminApiStatusTransport::Error`. The transport still raises only the exception class name; the provider response remains the existing generic `upstream_error` and does not expose TLS/certificate messages.
- The response root shape remains `generatedAt`, `cached`, and `providers`. No provider or metric state union was changed.
- Existing aggregation is deliberately retained: when both configured Datadog metric calls succeed without samples, each metric is `unavailable`/`no_data`, while the Datadog provider remains `unconfigured`. This compatibility behavior is now pinned by a service spec pending explicit contract agreement.
- Finite values outside the semantic ranges are deliberately retained: `101.0` percent and `-1.0` milliseconds remain available values. **TODO:** agree whether a later contract revision rejects or classifies out-of-range values; do not silently clamp them.

## Relevant Files

- `app/services/admin_api_status_transport.rb` — `AdminApiStatusTransport#request`; TLS exception normalization.
- `spec/services/admin_api_status_spec.rb` — both-Datadog-no-data aggregation and finite out-of-range passthrough coverage.
- `spec/requests/admin_api_status_spec.rb` — explicit 401/403 coverage and real-transport TLS isolation/cache/response-contract coverage using local HTTP doubles.
- `.agent/admin-api-status.md` — records TLS normalization, Datadog aggregation compatibility, and numeric-range TODO.

## Migration / Investigation Notes

### Implementation and contract review

1. `OpenSSL::SSL::SSLError` was added to the existing transport rescue list rather than handled in individual providers. Consequently Statuspage TLS failure follows the established generic `upstream_error` path while Datadog can still return its independently collected values.
2. The TLS request spec uses a fresh `ActiveSupport::Cache::MemoryStore`, stubs `Rails.cache`, has the Statuspage HTTP double raise `OpenSSL::SSL::SSLError`, and supplies successful responses for the two Datadog calls. It verifies:
   - first response: HTTP 200, `Cache-Control: no-store`, unchanged root keys, `cached: false`, generic Statuspage error without TLS message, and available Datadog metrics;
   - second response: HTTP 200, `Cache-Control: no-store`, `cached: true`, unchanged root keys, and no additional HTTP calls (the doubles expect exactly one Statuspage and two Datadog requests across both requests).
3. The request spec has separate examples for unauthenticated 401 and applicant-session 403. It deliberately does not assert `Cache-Control` on those authorization errors because `AdminApiStatusController#show` sets the header after authorization.
4. Source and changed specs were read after editing, then the diff was checked. No response-shape, provider-state-union, or metric-state-union production code was changed.

### Commands and observed results

| Command | Input / observed result | Exit |
| --- | --- | ---: |
| `git -C backend fetch origin` | Completed; `origin/main` resolved to `31ecd5d7f3d0532f1b4a2e0c6b28c43366574436`. | 0 |
| `git -C backend worktree add .worktree/fix/api-status-robustness -b fix/api-status-robustness origin/main` | Created this worktree and branch at `31ecd5d7f3d0532f1b4a2e0c6b28c43366574436`. | 0 |
| `docker -v` | `Docker version 28.0.4, build b8034c0`. | 0 |
| `ruby --version; bundle --version` | Ruby executable was not found; the bundle shim could not locate Ruby. | 127 |
| `cd backend/.worktree/fix/api-status-robustness && docker compose --env-file .env.example run --rm -e RAILS_ENV=test -e DATABASE_URL=postgresql://anabuki:anabuki@postgres:5432/anabuki_event_rails_test -e OPERATOR_DATABASE_URL=postgresql://anabuki:anabuki@postgres:5432/anabuki_event_operator_test app sh -lc 'bundle exec rails db:prepare && bundle exec rspec spec/services/admin_api_status_spec.rb spec/requests/admin_api_status_spec.rb'` | Docker CLI was installed, but the Docker Desktop Linux Engine pipe was unavailable while resolving `postgres:16-alpine`; no container, database, spec, or external provider request was run. | 1 |
| `git -C backend/.worktree/fix/api-status-robustness diff --check` | No whitespace errors. | 0 |

The direct CI command that remains required in an environment with Ruby 3.4.7, bundled gems, and PostgreSQL is:

```sh
bundle exec rspec spec/services/admin_api_status_spec.rb spec/requests/admin_api_status_spec.rb
```

## Recommended Next Steps

1. Run the stated RSpec command in CI or a Ruby 3.4.7 environment with the test PostgreSQL dependencies available.
2. Review the resulting request-spec behavior with the frontend contract owner before changing the intentionally pinned Datadog `unconfigured` aggregate behavior.
3. Resolve the numeric-range TODO by an explicit contract decision; preserve the current passthrough behavior until that decision is made.
