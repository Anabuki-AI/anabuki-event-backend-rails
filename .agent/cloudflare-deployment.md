# Cloudflare deployment review/fix

## Confirmed implementation

- `cloudflare/src/index.ts` uses the official `@cloudflare/containers` 0.3.7 SDK (`Container`, `getContainer`), `defaultPort = 8080`, `pingEndpoint = /health`, and `envVars` for Rails runtime secrets/vars.
- `cloudflare/wrangler.jsonc` uses `image: "../Dockerfile"`; Cloudflare's Containers deploy docs require the Dockerfile path itself, not its directory. The root Dockerfile and `Gemfile.lock` remain in the Docker build context. `workers_dev: false` is set so the backend has no public workers.dev endpoint; frontend access is via the service binding. No fixed domain route is configured because DNS/domain change is intentionally out of scope.
- Missing required Rails secrets return HTTP 503 with names only, never secret values. The Rails container is not started when configuration is incomplete. `secrets.required` in `cloudflare/wrangler.jsonc` does not register secrets; the README's approved-operator `wrangler secret put` loop is the bootstrap. Its 16 names match the Worker validation list exactly; `R2_REGION` remains a non-secret `vars` value.
- Production CMD starts Rails only. It does not run `db:prepare` or any migration automatically.
- Hyperdrive is intentionally not bound. The shared ID `7d2c5dac9bbd4bbca23b3a0a66116804` is not used because official Hyperdrive docs describe the generated secure connection string as accessible only from the Worker and the connection lifecycle as Worker-edge-to-Hyperdrive plus Hyperdrive-to-origin pooling. Passing `env.HYPERDRIVE.connectionString` into a Rails Container is therefore not a supported assumption; no such integration is recommended without separate official/technical validation.
- Wrangler 4.133.0 exposes `containers ssh`, not `containers exec`. The SDK's `ctx.container.exec()` is only available inside an RPC method; this Worker intentionally exposes no migration RPC. The supported migration path is an approved local workstation or manual CI job with the exact commit and secret-manager-injected `RAILS_ENV=production`, `DATABASE_URL`, and `OPERATOR_DATABASE_URL`, followed by `db:migrate:status:primary`, `db:migrate:status:operator`, the two explicit migrate tasks, and final status verification. `db:prepare` is not run automatically and is not recommended for an existing production target because it may create a database.
- CI deployment targets GitHub `production`, has a non-canceling Cloudflare deployment concurrency lock, is gated by `check`, and runs only on main push or main `workflow_dispatch`. Before credentials/install/deploy, each deploy job compares its event SHA with the current GitHub `main` ref and skips stale queued runs, preventing an old main deployment from rolling back a newer one. `notify-parent` and `deploy-production` intentionally remain parallel siblings after `check`; parent gitlink synchronization is not a deployment prerequisite.

## Verification evidence

- `mise exec -- npm ci --ignore-scripts` in `cloudflare/`: exit 0, Node 22.19.0, 42 packages, no vulnerabilities.
- `mise exec -- npx wrangler --version`: exit 0, Wrangler 4.133.0.
- `mise exec -- npx wrangler containers --help`: exit 0; confirmed `ssh`/`instances` and absence of a CLI `exec` command.
- `mise exec -- npx wrangler deploy --dry-run --containers-rollout=none --config wrangler.jsonc`: exit 0; Wrangler recognized `RailsContainer`, port/container Dockerfile path, Durable Object binding, and vars.
- `mise exec -- npx wrangler deploy --dry-run --config wrangler.jsonc`: exit 1 only because the local Docker daemon was unavailable; Wrangler explicitly required Docker for a configured Dockerfile image. No credentials or real deployment were attempted.
- `mise exec -- bundle exec rails -T | grep 'db:(migrate|prepare|schema)'`: exit 0; confirmed separate primary/operator migration tasks.

## Official references consulted

- https://developers.cloudflare.com/containers/get-started/
- https://developers.cloudflare.com/containers/guides/deploy/
- https://developers.cloudflare.com/containers/guides/execute-commands/
- https://developers.cloudflare.com/containers/guides/ssh/
- https://developers.cloudflare.com/containers/reference/container-class/
- https://developers.cloudflare.com/workers/wrangler/configuration/
