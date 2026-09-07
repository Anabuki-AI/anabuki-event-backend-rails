# Anabuki Event Backend Rails

`anabuki-event-backend` の Javalin API を置き換える Rails 8 API です。Nuxt frontend 互換の `/health`、`/api/users`、Google OAuth と管理者承認 API のレスポンス形式・Cookie名を維持しています。

## 保護範囲と設計

- PostgreSQL と Active Record migration
- `POST /api/users` は BCrypt (`has_secure_password`) でパスワードをハッシュ化します。レスポンスに password/digest は含めません。
- Google OpenID Connect ID token を署名・audience 検証してから identity を作成します。
- 管理者の device cookie と session cookie はランダム値を HttpOnly/SameSite=Lax で発行し、DBには SHA-256 hash だけを保存します。
- applicant request は正確な device/session pair に紐付けます。ログアウト、再ログイン、失効、管理権限取消時は未処理申請を `CANCELLED` にします。
- 状態変更 API は `Origin` が `PUBLIC_BASE_URL` または `ADMIN_FRONTEND_URL` と同一 origin の場合だけ受け付けます（non-browser client は従来どおり Originなしで利用可能）。

## Migration safety

Rails は **別DB** `anabuki_event_rails_*` と、別Docker volume `rails-postgres-data` を使用します。Java/Flyway の `anabuki_event` DB、既存の volume、または本番DBをこのリポジトリで reset/migrate しないでください。実データ移行は承認済みのバックアップ・dry-run・照合計画を含む別作業です。

## Background jobs (Que)

Active Job は Redisを使わず、PostgreSQL-backed [Que](https://github.com/que-rb/que) adapterを使用します。`db/migrate/*create_que_schema.rb` が公式の `Que.migrate!(version: 7)` を適用し、workerはAPIとは別プロセスで起動します。RailsのDB migrationはComposeの `db-prepare` サービスだけが先に実行するため、APIとworkerの同時起動によるmigration競合を避けます。

```bash
# Compose: PostgreSQL -> db-prepare -> API + Que worker
 docker compose --env-file .env up --build

# ローカルRubyでworkerを動かす場合（DBが起動済みであること）
bundle exec que --worker-count 3 \
  --queue-name default \
  --queue-name mailers \
  --queue-name action_mailbox_incineration \
  --queue-name action_mailbox_routing \
  --queue-name active_storage_analysis \
  --queue-name active_storage_purge
```

アプリケーションジョブは通常どおり `ApplicationJob` を継承して `perform_later` でenqueueします。CIの `spec/jobs/que_integration_spec.rb` は実際に `que_jobs` PostgreSQLテーブルへenqueueし、QueのActive Job wrapperでpayloadを実行します。

## Sentry

`sentry-rails` は `SENTRY_DSN` が設定された環境だけで使用します。デフォルトの有効環境は `production` で、`SENTRY_ENABLED_ENVIRONMENTS` をカンマ区切りで変更できます。`SENTRY_ENVIRONMENT` と `SENTRY_RELEASE`（未設定時は `GIT_COMMIT`）をイベントへ設定します。開発/testはDSNがあってもデフォルトでは送信しません。

`send_default_pii = false` に加えて、cookie、authorization/token系ヘッダ、request body、query parameter、user情報、DB query data、Que job argumentsを収集しない設定にしています。Railsのparameter filterでも password、email、credential、Google token等をログから除外します。SentryのActive Job integrationがQue adapter上のジョブ例外を報告します。workerプロセス終了時の取りこぼしを避けるため、この連携は同期captureを利用します。

実DSNへの送信はこの変更では検証していません。DSNはGitHub Actions secretまたはデプロイ環境のsecret storeにだけ設定してください。

## Local development

Ruby 3.4+、Docker Desktopを用意します。機密値を表示・commitしないでください。

```bash
cp .env.example .env
bundle install
bundle exec rspec
bundle exec rubocop
bundle exec brakeman --no-pager
bundle exec rails zeitwerk:check
# Docker Desktop が起動済みの場合
# docker compose --env-file .env up --build
```

API: `http://localhost:8080`、health check: `GET /health`。

主なAPI:

```text
GET  /health
GET  /api/users/:id
POST /api/users                       { userName, email, password }
GET  /api/auth/google/status
GET  /api/auth/google/start
GET  /api/auth/google/callback
GET  /api/admin/auth/session
POST /api/admin/auth/logout
POST /api/admin/auth/exchange
GET/POST /api/admin/access-request
GET  /api/admin/access-requests
POST /api/admin/access-requests/:id/approve
POST /api/admin/access-requests/:id/reject
GET/DELETE /api/admin/allowed-emails(/:id)
```

## Configuration

Copy `.env.example`; values named `GOOGLE_CLIENT_SECRET`, `POSTGRES_PASSWORD`, and `SECRET_KEY_BASE` must come from a local/deployment secret store. `SECRET_KEY_BASE` is mandatory in production (`bin/rails secret` generates one). Register `GOOGLE_OAUTH_CALLBACK_URL` exactly in Google Cloud Console. Set HTTPS public URLs in production so cookies get the `Secure` flag.

## CI

GitHub Actions runs Brakeman, RuboCop, Zeitwerk, and RSpec against PostgreSQL. RSpec includes API/user/auth coverage and a PostgreSQL Que enqueue/execution smoke spec. CI never needs a Sentry DSN, so no event is sent during checks.
