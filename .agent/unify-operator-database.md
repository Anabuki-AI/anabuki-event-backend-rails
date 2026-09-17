# Operator database unification

## Scope

Branch: `unify-operator-database`

The operator authentication tables now use the Rails primary connection. The legacy operator connection variable, the `operator` database configuration, and `connects_to` are removed. The existing `db/operator_migrate/` files are retained unchanged as historical input; Rails loads only `db/migrate`.

## Migration design

`db/migrate/20260918060100_create_operator_tables_in_primary.rb` creates the final operator schema in the primary PostgreSQL database:

- `operator_identities`: UUID primary key, deterministic encrypted `text` email, unique Google subject, manager grant/revocation fields.
- `operator_device_sessions`: UUID primary key, FK to `operator_identities`, binary token hashes, deterministic encrypted `text` email snapshot, access-source check constraint, expiry index.
- `operator_oauth_states`: legacy bigint primary key, binary unique state hash, expiry index.

`operator_access_requests` is intentionally not created: the final operator migration history removes that obsolete table, and no current model/controller uses it. Existing main migrations were not edited.

## Email encryption decision

Google OAuth needs both of these operations:

1. Find an existing operator by normalized email (`Operator::Identity.find_by(email: ...)`).
2. Reject a second Google subject for an already-used normalized email.

`Operator::Identity` therefore declares `encrypts :email, deterministic: true`. Normalization (`strip.downcase`) happens before validation and encryption, so an exact deterministic query is sufficient. The normal unique index remains valid because equivalent normalized emails produce equivalent deterministic ciphertext. The prior case-insensitive uniqueness validator was changed to exact uniqueness; a SQL `LOWER(email)` lookup would not be a valid deterministic-encryption query and is unnecessary after normalization.

`Operator::DeviceSession` encrypts its denormalized `email` snapshot as well. It is not unique or queried independently. Management listing sorts decrypted values in Ruby instead of ordering ciphertext in PostgreSQL.

No custom cipher, digest lookup, or plaintext fallback is used. Rails model reads transparently decrypt the value.

## Configuration

Production requires these non-blank environment values:

- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`

Generate local values with `bin/rails db:encryption:init`, then put them only in the approved deployment secret store. Values are not included in this branch. Development and test use fixed non-production defaults when variables are absent; test and production both set `support_unencrypted_data = false`.

The Cloudflare Worker guard, deployment bootstrap workflow, `.env.example`, and README carry the three names. No legacy operator connection variable is supplied to Rails or Cloudflare.

## Existing data caveat

Whether a real production migration has already run is unconfirmed. This branch has no source operator database URL and does not automate data transfer. Before any real deployment, the database owner must take verified backups, inspect both schemas, choose whether to migrate identities/sessions/OAuth states, and approve a dry-run against isolated clones. The safe default is to migrate identities through reviewed `Operator::Identity` model writes using the production encryption keys, invalidate old sessions, and require Google OAuth again. Do not copy plaintext email using SQL. Verify counts, normalized emails, Google subjects, manager fields, UUID collisions, and indexes after the move.

## Verification plan

Run from this worktree only:

```bash
bundle exec rails db:prepare
bundle exec rspec
bundle exec rubocop
bundle exec brakeman --no-pager -q
bundle exec rails zeitwerk:check
bundle exec rails db:migrate:status
(cd cloudflare && npm ci && npm run typecheck)
(cd cloudflare && npx wrangler deploy --dry-run --containers-rollout=none --config wrangler.jsonc)
git diff --check
```

Use only a uniquely named local PostgreSQL container/port for database checks. Do not run these commands against the root checkout, an existing project Compose volume, PlanetScale, Cloudflare, GitHub secrets, or any production database.

## Verification record

- `docker build --target development --tag anabuki-event-unify-operator-test:local ...`: exit 0.
- Isolated Docker PostgreSQL 16 test database: `db:prepare` exit 0; all migrations, including `20260918060100_create_operator_tables_in_primary`, applied to one database.
- `bundle exec rspec`: exit 0, 209 examples, 0 failures. The new raw-column tests verified identity and session email values did not contain plaintext, model reads decrypted values, deterministic lookup worked, and both model/DB uniqueness paths passed. A second isolated run without encryption environment variables also passed the four new schema/encryption examples using test-only defaults.
- `bundle exec rails db:migrate:down/up VERSION=20260918060100`: exit 0; operator schema rollback and re-apply succeeded.
- `bundle exec rubocop`: exit 0, 139 files, no offenses.
- `bundle exec brakeman --no-pager -q`: exit 0, 0 warnings.
- `bundle exec rails zeitwerk:check`: exit 0.
- `actionlint .github/workflows/ci.yml`: exit 0.
- Cloudflare `npm run typecheck` and `wrangler deploy --dry-run --containers-rollout=none`: exit 0 under mise Node 22.19.0 / Wrangler 4.133.0.
- Production boot without the first encryption key: exit 1 with `KeyError`; no production DB connection was attempted.

Host Ruby was unavailable (`ruby --version` exit 127), so Ruby checks used the isolated development image. No production or external operator database was contacted.
