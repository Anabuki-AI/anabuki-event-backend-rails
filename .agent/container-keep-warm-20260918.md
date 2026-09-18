# Cloudflare Container keep-warm cron

- Repository: `Anabuki-AI/anabuki-event-backend-rails`
- Branch: `feat/container-keep-warm`
- Base: `origin/main` at `6da1fd0510b5dd3d63b0a62ac4ce4d4208faa52c`
- Worktree: `anabuki-event/.worktree/feat/container-keep-warm`
- Date: 2026-09-18

## Purpose

`RailsContainer` の cold start（既存調査で first wake 約8.14秒）を、JST昼間帯に Worker Cron から Rails の health endpoint へ到達させることで減らす。既存の RailsContainer の `sleepAfter = '10m'`、`max_instances = 1`、`pingEndpoint = 'container/health'`、通常の `fetch` ハンドラは変更していない。

## Latest main preflight

実装前に以下を実行した。

```text
git -C backend fetch origin
```

- 終了コード: `0`
- 最新 `origin/main`: `6da1fd0510b5dd3d63b0a62ac4ce4d4208faa52c`

以下を `origin/main` に対して確認した。

```text
git -C backend grep -n -E 'scheduled\s*\(|triggers|crons' origin/main -- cloudflare/src/index.ts cloudflare/wrangler.jsonc
```

- `scheduled()`, `triggers`, `crons` の出力なし。つまり着手時点の最新 main には scheduled handler と cron 設定が無かった。
- その後、指定どおり `origin/main` から worktree を作成した。

## Implementation

### `cloudflare/wrangler.jsonc`

以下の UTC cron を追加した。

```jsonc
"crons": ["*/5 0-14 * * *", "*/5 23 * * *"]
```

- UTC 23:00 は JST 翌日 08:00。
- UTC 00:00--14:59 は JST 09:00--23:59。
- 合わせて JST 08:00--23:59 のみ5分間隔で ping する。
- JST 00:00--07:59 は cron を止め、夜間の active duration を抑える。
- 毎朝 JST 08:00 の最初の ping で再び Container を warm 化する意図を JSONC コメントに記載した。

### `cloudflare/src/index.ts`

default export に `scheduled(_controller, env, ctx)` を追加した。

- `getContainer(env.RAILS_CONTAINER, 'production')` で通常 fetch と同じ Durable Object Container を取得。
- `ctx.waitUntil(...)` 内で `http://container/health` を fetch。これは既存 `pingEndpoint = 'container/health'` の Rails `/health` を叩く URL。
- fetch 失敗時は `console.error('Container keep-warm ping failed', error)` を1回出すだけ。
- リトライ、失敗回数カウンタ、外部監視、アラートは追加していない。

## Cost and removal

この設定は JST 08:00--23:59 の間、5分ごとの ping で `sleepAfter = '10m'` の idle sleep を抑えるため、Container の active duration 課金が昼間帯に継続して発生する可能性がある。スケジュールは1日あたり最大192回（16時間 × 12回/時）で、正確な金額は Cloudflare の契約プラン・Container の料金単価・実際の起動時間に依存する。cron は deploy、eviction、障害などによる cold start を保証して排除するものではない。

keep-warm を外す場合は `cloudflare/wrangler.jsonc` の `triggers` ブロック（`crons` 2件）を削除して再デプロイする。通常の fetch handler や `RailsContainer` の health 設定を変更する必要はない。コード側の `scheduled()` も不要になるため、cron を完全に撤去する場合は同じ PR/変更で削除する。

## Verification

| Command | Result |
|---|---|
| `cd cloudflare && mise exec -- npm run typecheck` | 終了コード `0`; Wrangler `4.133.0` が型を生成し、`tsc --noEmit` 成功。Node `v22.19.0`。 |
| `cd cloudflare && mise exec -- npx wrangler deploy --dry-run --containers-rollout=none --config wrangler.jsonc` | 終了コード `0`; JSONC を読み込み、`RailsContainer`、port `8080`、Dockerfile image、DO binding を認識。実デプロイなし。 |
| `git diff --check` | 終了コード `0`。 |
| `RAILS_ENV=test DATABASE_URL=... mise exec -- bundle exec rspec` | 終了コード `1`; Rails 側に未適用 migration `20260918090000_add_is_selected_relay_question_to_questions.rb` があり、RSpec 起動時の pending migration check で停止。migration 適用や Rails コード変更は行っていない。 |

Node modules と Wrangler 生成の `cloudflare/worker-configuration.d.ts` は worktree 内の ignore 対象であり、コミット対象外。
