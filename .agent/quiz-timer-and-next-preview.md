# クイズタイマー・次問題プレビュー API

- 日付: 2026-09-18
- ブランチ: `feature/quiz-timer-and-next-preview`
- 作業場所: 親プロジェクト `.worktree/feature-quiz-timer-and-next-preview-backend`
- 基点: `origin/main` の `31ecd5d`（配点 PR #32 マージ済み）。作業再開時に fetch 済み。

## 引き継ぎとスコープ

Claude Code が「PRを作成して」の指示後、worktree 新設直後に停止していた作業を継続。
`backend/` の main 作業ツリーからタイマー関連の変更のみを移植した。
main 作業ツリーの既存未コミット変更・他 worktree・開発 DB はこの PR 作業で変更していない。
配点の実装は基点 main のまま維持し、採点ロジックは変更していない。

## API 契約

- 問題 CRUD: `timeLimitSeconds`（別名 `time_limit_seconds`）は null または 1〜2147483647 の整数。
  - 作成時省略は null、更新時省略は既存値維持。
  - null / 空の multipart 文字列で解除。
  - 数値文字列を10進数として処理する。先頭ゼロ付き `045` も45秒。
  - 型不正・範囲外は422と `fieldErrors.timeLimitSeconds`。DB integer 上限超過でも500にしない。
- `GET /api/operator/quiz/state` と各遷移レスポンス:
  - `phase_started_at`: ISO8601 / null。start、publish、close、reveal、finish、reset で更新。
  - `current.time_limit_seconds`: 設定秒数 / null。
  - `next_question`: 次 position の問題を `question_id` / `position` / `question_text` / `choices` / `image_url` で返す。正解・回答統計は含めない。
  - 待機・終了・最終問題では `next_question` は null。
- 既存の現在問題表示用フィールド（問題文・全選択肢・運営者向け正解・回答数）は維持。

制限時間カウントダウンと時間切れ時の自動締切は、対応 frontend がこの時刻と制限時間から計算し、既存 `POST /api/operator/quiz/close` を呼ぶ構成。
サーバーの独立した期限ジョブは追加していないため、運営画面を閉じた状態での自動締切はこの実装の対象外。

## マイグレーション

- `20260918050000_add_time_limit_seconds_to_questions.rb`: nullable integer。
- `20260918050100_add_phase_started_at_to_quiz_sessions.rb`: nullable datetime。
- 既存問題は制限時間なし、既存セッションの初期時刻は null。新たなフェーズ遷移から時刻を保持する。
- 本番 DB の操作は行っていない。PR 適用時は通常のデプロイ手順でマイグレーションが必要。

## 検証

Ruby 3.4.7 / ローカル PostgreSQL 5433、`RAILS_ENV=test`、primary/operator とも専用 test DB を使用。

- `bundle exec rails db:prepare`: 成功（test DB のみ）。
- `bundle exec rspec`: **192 examples, 0 failures**。
- `bundle exec rubocop --cache false`: **135 files inspected, no offenses**。
- `git diff --check`: 成功。
- 先頭ゼロの回帰テストは修正前に `045 → 37` で失敗し、10進変換修正後に成功。
- 省略時の保持・空文字解除、型不正・範囲超過、時刻更新、次問題の全選択肢と正解除外を検証。

Bundler がローカル OS 用に追加した `Gemfile.lock` の platform 行は PR に含めず戻した。
ブラウザでの結合検証は frontend 作業記録を参照。
