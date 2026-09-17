# Anabuki Event Backend Rails

`anabuki-event-backend` の Javalin API を置き換える Rails 8 API です。管理者・運営者の認証は Google OAuth を使用し、参加者は UUID + Cookie セッションで登録します。Nuxt frontend 互換の `/health`、Google OAuth と管理者承認 API のレスポンス形式・Cookie名を維持しています。

## 保護範囲と設計

- PostgreSQL と Active Record migration
- 参加者は `POST /api/participants` で UUIDとして登録します。表示名は非一意で、認証識別子ではありません。`participants` と `participant_sessions` は pgcrypto UUIDを使用します。
- 参加者登録ではランダムな不透明トークンを `HttpOnly; SameSite=Lax` cookieに発行し、DBには SHA-256 hashだけを保存します。これは管理者・運営者認証とは独立した `ParticipantAuth` です。
- Google OpenID Connect ID token の署名・audience・nonce・確認済みメールを検証してから `AdminIdentity` を作成します。再ログインは同じ Google identity を使用します。
- 初回ログインは `APPLICANT`（管理権限なし）です。`ADMIN_EMAIL_ALLOWLIST` による環境アクセス、または承認済みの管理アクセスだけが管理画面を利用できます。
- 管理者の device cookie と session cookie はランダム値を HttpOnly/SameSite=Lax で発行し、DBには SHA-256 hash だけを保存します。
- applicant request は正確な device/session pair に紐付けます。ログアウト、再ログイン、失効、管理権限取消時は未処理申請を `CANCELLED` にします。
- `ADMIN_EMAIL_ALLOWLIST` は各認証リクエストで再評価する環境アクセスです。承認済み管理者と環境アクセスは、他者の通常管理権限だけを取消できます。自分自身と環境アクセスは取消できません。
- 状態変更 API は `Origin` が `PUBLIC_BASE_URL` または `ADMIN_FRONTEND_URL` と同一 origin の場合だけ受け付けます（non-browser client は従来どおり Originなしで利用可能）。参加者・オペレーター向けAPIも同様に、それぞれ `PUBLIC_BASE_URL` / `OPERATOR_FRONTEND_URL` と同一 originのみを受け付けます。イベント当日など複数端末（参加者のスマホ等）がLAN経由の別IPでdevサーバーへアクセスする場合は、`ADDITIONAL_ALLOWED_ORIGINS`（カンマ区切りの追加許可origin。例: `http://192.168.1.50:3000,http://192.168.1.51:3000`）で単一の `PUBLIC_BASE_URL` を書き換えずに追加のoriginを許可できます。

## Punditによる管理認可

Pundit は**判定だけ**を担当します。Google OAuth の認証、device-bound な DB セッションの検証、申請と承認の状態遷移は既存の `AdminAuth` が引き続き担当し、Policy は `AdminAuth::Session` が検証済みの permission を読むだけです。

| 権限区分 | 自分の申請 | 管理セッションへのexchange | 申請一覧・承認/却下 | 管理者一覧 | 管理権限の取消 |
| --- | --- | --- | --- | --- | --- |
| `APPLICANT` | 可 | 承認済みかつ元の device/session pair のときだけ可 | 不可 | 不可 | 不可 |
| `MANAGEMENT_ACCESS` | 不可 | 不可 | 可 | 可 | 他者の `MANAGEMENT_ACCESS` のみ可 |
| `ENVIRONMENT_ACCESS` | 不可 | 不可 | 可 | 可 | 他者の `MANAGEMENT_ACCESS` のみ可 |

管理者のみの `GET /api/admin/api-status` も `MANAGEMENT_PAGE_VIEW` で保護されます。Statuspage と Datadog の集約値は、外部設定が無い場合に正常と見なさない `unconfigured` 状態を返します。契約とプロバイダ設定は [`.agent/admin-api-status.md`](.agent/admin-api-status.md) を参照してください。

`ADMIN_EMAIL_ALLOWLIST` にあるメールアドレスは、申請・承認なしで最初の `ENVIRONMENT_ACCESS` を取得できる初期管理者例外です。この環境アクセスは各認証リクエストで再評価されます。`MANAGEMENT_ACCESS` と `ENVIRONMENT_ACCESS` はどちらも他者の通常管理権限を取消できますが、自分自身および `ENVIRONMENT_ACCESS` は取消できません。

認可を含む確認コマンド:

```bash
bundle exec rspec
bundle exec rubocop
bundle exec rails zeitwerk:check
bundle exec brakeman --no-pager -q
```

## Migration safety

Rails は **別DB** `anabuki_event_rails_*` と、別Docker volume `rails-postgres-data` を使用します。Java/Flyway の `anabuki_event` DB、既存の volume、または本番DBをこのリポジトリで reset/migrate しないでください。実データ移行は承認済みのバックアップ・dry-run・照合計画を含む別作業です。

このリポジトリで管理する未マージの初期migrationには、参加者用の認証情報テーブルを含めません。Google identityへの自動変換・メール一致によるアカウント連携は行いません。

## Google OAuth integration

管理者フロントエンドは `GET /api/auth/google/status`、オペレーターフロントエンドは `GET /api/auth/operator/google/status` でそれぞれの設定状態を確認します。ログイン開始も管理者は `GET /api/auth/google/start`、オペレーターは `GET /api/auth/operator/google/start` に分離されています。Google のコールバックが成功すると、管理者は `ADMIN_FRONTEND_URL`、オペレーターは `OPERATOR_FRONTEND_URL` へ戻ります。オペレーター用の `OPERATOR_GOOGLE_OAUTH_CALLBACK_URL` は Google Cloud Console に完全一致で登録してください。OAuth 未設定時にパスワード認証へフォールバックすることはありません。

## Participant registration

参加者は `POST /api/participants` で表示名とアンケート回答を送信すると、UUID参加者とCookieセッションが作られます。`GET /api/participants/me` はCookieから現在の参加者を返し、`DELETE /api/participants/session` はセッションをrevokeしてCookieを削除します。待機画面の `POST /api/participants/reactions` はセッションごとに500msに1件だけイベントを保存し、連打はイベントを作成せず `429 Too Many Requests` を返します。完全なrequest/response契約は [`.agent/participant-api-contract.md`](.agent/participant-api-contract.md) を参照してください。

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
POST /api/participants
GET  /api/participants/me
POST /api/participants/presence
POST /api/participants/reactions
DELETE /api/participants/session
GET  /api/auth/google/status
GET  /api/auth/google/start
GET  /api/auth/google/callback
GET  /api/auth/operator/google/status
GET  /api/auth/operator/google/start
GET  /api/auth/operator/google/callback
GET  /api/admin/auth/session
GET  /api/admin/api-status
POST /api/admin/auth/logout
POST /api/admin/auth/exchange
GET/POST /api/admin/access-request
GET  /api/admin/access-requests
POST /api/admin/access-requests/:id/approve
POST /api/admin/access-requests/:id/reject
GET/DELETE /api/admin/allowed-emails(/:id)
GET  /api/admin/questions
POST /api/admin/questions
GET/PUT/DELETE /api/admin/questions/:id
GET  /api/admin/confidence-multipliers
PATCH /api/admin/confidence-multipliers/:level
```

### 問題管理 API

問題管理 API は既存の device-bound な管理セッションと `MANAGEMENT_PAGE_VIEW` Pundit permission を必要とします。`POST`、`PUT`、`DELETE`、`PATCH` は同一 origin 保護の対象です。`GET /api/admin/questions` は `position` 順で返し、作成時の `position` は末尾に安全に採番されます（削除後の欠番は維持します）。

問題の作成・更新には `questionText`、`choiceA`〜`choiceD`、`correctAnswer` (`A`〜`D`) を JSON で送り、任意の `imageUrl` は `null` または HTTP(S) URL にします。レスポンスは `id`、`position`、上記の問題フィールド、`imageUrl`、`createdAt`、`updatedAt` を返します。入力検証エラーは `422 { "error": "...", "fieldErrors": { "questionText": "..." } }` です。初期の編集画面互換として、作成・更新では `choices: { A, B, C, D }` と `correctChoice` も受け付けます。

自信度倍率は `GET /api/admin/confidence-multipliers` で常に `{ "high": "2.00", "normal": "1.00", "low": "0.50" }` 形式（更新済みの値を含む）を返します。`PATCH /api/admin/confidence-multipliers/:level` は `{ "confidenceMultiplier": number }` を受け、`high`、`normal`、`low` のいずれかを 0〜9.99・小数第2位までで更新します。

## Configuration

Copy `.env.example`; values named `GOOGLE_CLIENT_SECRET`, `POSTGRES_PASSWORD`, `SECRET_KEY_BASE`, `STATUSPAGE_API_KEY`, `DATADOG_API_KEY`, and `DATADOG_APP_KEY` must come from a local/deployment secret store. `SECRET_KEY_BASE` is mandatory in production (`bin/rails secret` generates one). Register both `GOOGLE_OAUTH_CALLBACK_URL` and `OPERATOR_GOOGLE_OAUTH_CALLBACK_URL` exactly in Google Cloud Console, and keep `OPERATOR_FRONTEND_URL` pointed at the operator portal rather than the admin portal. Set HTTPS public URLs in production so cookies get the `Secure` flag. Statuspage/Datadog environment setup and the admin status response contract are documented in [`.agent/admin-api-status.md`](.agent/admin-api-status.md).

## CI

GitHub Actions runs Brakeman, RuboCop, Zeitwerk, and RSpec against PostgreSQL. RSpec covers UUID participant registration, hashed Cookie sessions and their revocation, Google OAuth registration/login and callback rejection (with external Google calls stubbed), Pundit authorization and admin access revocation, origin policy, and a PostgreSQL Que enqueue/execution smoke spec. CI never needs a Sentry DSN, so no event is sent during checks.
