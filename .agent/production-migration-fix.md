# Initial production migration safety fix

## Scope

Branch `fix-initial-production-migration` is based on backend `origin/main` at
`f83c8659d312527e9bf3bd71d5df449c9aa33dd0`. The change is limited to the
production migration workflow, a read-only database inventory runner, and the
production Docker image CA bundle.

## Workflow behavior

- `script/production_database_inventory.rb` performs one read-only
  `information_schema.tables` query for public base tables.
- It reports public table count and table names only. It exits with a distinct
  code for an empty database without `schema_migrations`, an unknown partial
  state (public tables but no `schema_migrations`), an unexpected public table,
  a ready database, and a connection/configuration failure. The expected table
  set is explicit and includes Rails metadata plus Que tables, so an unrelated
  public table blocks migration even when the ledger exists.
- Status mode reports `initial database: schema_migrations absent` for the
  empty initial state and does not invoke `db:migrate:status` in that state.
- Apply mode still requires the exact `MIGRATE_PRODUCTION` confirmation. It
  runs `rails db:migrate` only after the read-only inventory proves the public
  schema is empty, then runs a post-migration inventory and status check.
- Existing databases use the normal migration status checks; `NO FILE`, status
  failures, preflight failures, and migration failures stop without retry.
- Error output is captured and replaced with stable generic messages; raw
  adapter stderr, URLs, and secret values are not printed.
- No `db:prepare`, `db:create`, `db:drop`, schema load, DML, or role operation
  is part of the production path.

## Image validation

The final `ruby:3.4.7-slim` stage explicitly installs Debian
`ca-certificates` and asserts that
`/etc/ssl/certs/ca-certificates.crt` is non-empty during the image build.

## Verification record

- `actionlint .github/workflows/production-migration.yml`: passed.
- Production image build target and runtime CA-bundle test: passed; bundle was
  present and non-empty (224449 bytes in the test image).
- Isolated PostgreSQL initial inventory: exit `10`, public base tables `0`,
  `schema_migrations` absent.
- Isolated PostgreSQL inventory with an unexpected table and no ledger: exit
  `21`; apply was not attempted. A ready-state unexpected-table fixture is
  covered by the same exit policy (`22`).
- Isolated PostgreSQL initial migration through all migrations: passed; final
  public base table count `24`, `schema_migrations` present, pending migrations
  `0`, `NO FILE` entries `0`.
- Dockerized RSpec: `226 examples, 0 failures` on the rerun after one transient
  timing failure.
- Dockerized RuboCop: `147 files inspected, no offenses detected`.
- Dockerized Brakeman: `0` errors, `0` security warnings.
- Dockerized Zeitwerk check: `All is good!`.
- `git diff --check`: passed.

No production database credentials, Cloudflare credentials, URLs, or query
results from production are stored in this file.
