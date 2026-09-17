# Cloudflare container health probe fix

- Repository: `Anabuki-AI/anabuki-event-backend-rails`
- Branch: `fix-container-health-probe`
- Base: `origin/main` at `e0e0e93`
- Scope: make the Cloudflare Containers supervisor probe the Rails health route using the SDK's host/path format.

## Finding

`@cloudflare/containers` builds the probe as `http://${pingEndpoint}`. Its README documents `container/health` as the host/path form. The prior path-only value `/health` therefore produced an invalid probe target for the container supervisor, while the service-binding requests surfaced as a generic frontend HTTP 500.

## Change

- Keep Rails' `GET /health` route unchanged.
- Change `RailsContainer#pingEndpoint` from `/health` to `container/health`.
- Keep the backend Worker private (`workers_dev: false`); no domain or DNS configuration is changed.

## Verification

- `mise exec -- node --version`: exit `0`; Node `v22.19.0`.
- `npm ci --ignore-scripts` in `cloudflare/`: exit `0`; 42 packages, 0 vulnerabilities.
- `mise exec -- npm run typecheck`: exit `0`; Wrangler `4.133.0` generated types and `tsc --noEmit` passed.
- `mise exec -- npx wrangler deploy --dry-run --containers-rollout=none --config wrangler.jsonc`: exit `0`; Wrangler recognized `RailsContainer`, port `8080`, and the Dockerfile image without contacting Cloudflare.
- `git diff --check`: exit `0`.

Production verification will record only HTTP status and non-sensitive response summaries. Secrets and response headers are not recorded.
