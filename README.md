# Anabuki Event Backend Rails

`anabuki-event-backend` の Javalin API を置き換える Rails 8 API です。Nuxt frontend 互換の `/health`、`/api/users`、Google OAuth と管理者承認 API のレスポンス形式・Cookie名を維持しています。

## 保護範囲と設計

- PostgreSQL と Active Record migration
- `POST /api/users` は BCrypt (`has_secure_password`) でパスワードをハッシュ化します。レスポンスに password/digest は含めません。
- Google OpenID Connect ID token を署名・audience 検証してから identity を作成します。
- 管理者の device cookie と session cookie はランダム値を HttpOnly/SameSite=Lax で発行し、DBには SHA-256 hash だけを保存します。
- applicant request は正確な device/session pair に紐付けます。ログアウト、再ログイン、失効、管理権限取消時は未処理申請を `CANCELLED` にします。
- `ADMIN_EMAIL_ALLOWLIST` は各認証リクエストで再評価する環境アクセスです。環境アクセスのみが他の管理権限を取消できます。
- 状態変更 API は `Origin` が `PUBLIC_BASE_URL` または `ADMIN_FRONTEND_URL` と同一 origin の場合だけ受け付けます（non-browser client は従来どおり Originなしで利用可能）。

## Migration safety

Rails は **別DB** `anabuki_event_rails_*` と、別Docker volume `rails-postgres-data` を使用します。Java/Flyway の `anabuki_event` DB、既存の volume、または本番DBをこのリポジトリで reset/migrate しないでください。実データ移行は承認済みのバックアップ・dry-run・照合計画を含む別作業です。

## Local development

Ruby 3.4+、Docker Desktop を用意します。機密値を表示・commitしないでください。

```bash
cp .env.example .env
bundle install
bundle exec rails test
# Docker Desktop が起動済みの場合
# `DATABASE_URL` を compose 外から使うときは localhost:5433 を指定する
docker compose --env-file .env up --build
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

GitHub Actions runs Brakeman, RuboCop, and Rails tests against PostgreSQL. A successful `main` run may notify the parent submodule repository when its `PARENT_REPOSITORY_TOKEN` secret is configured.
