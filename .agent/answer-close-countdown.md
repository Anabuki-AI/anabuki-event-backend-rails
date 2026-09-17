# 解答締め切りの10秒カウントダウン API

- 日付: 2026-09-20
- ブランチ: `feat/answer-close-countdown`
- 基点: `origin/main` (`769f51a`)

## 挙動と契約

運営者が `POST /api/operator/quiz/close` を実行すると、解答を即時に締め切らず、`QuizSession.phase` を `closing` にして10秒後の締め切りジョブを Que に登録する。

- `closing` 中は参加者の解答を受け付ける。`phase_started_at` はカウントダウン開始のサーバー時刻であり、operator/participant state の両方で ISO8601 として返す。
- `CloseQuizAnswersJob` は10秒後、同じ問題 ID と `phase_started_at` の `closing` 状態だけを `closed` へ進める。reset・次問・新しい締め切り要求後に残った古いジョブは何もしない。
- 参加者の解答リクエストがちょうど期限後に先に到着した場合も、トランザクション内で `closed` へ遷移して409を返す。
- `answering_started_at` を追加し、`closing` へ遷移しても問題ごとの `time_limit_seconds` の起点がリセットされないようにした。既存セッションは最初の締め切り要求時に旧 `phase_started_at` を引き継ぐ。
- `POST /api/operator/quiz/close` の `{ immediate: true }` は、既存の問題制限時間満了用の即時締め切り。通常の運営UIの手動ボタンは送らない。

## マイグレーション

- `20260918070000_add_closing_phase_to_quiz_sessions.rb`: phase check constraint に `closing` を追加。
- `20260918070100_add_answering_started_at_to_quiz_sessions.rb`: 問題の回答受付開始時刻を追加。

本番DBの操作はしていない。デプロイ時は通常の承認済み migration 手順で適用する。

## 検証

専用 PostgreSQL test DB（localhost:5433）で実行:

```sh
bundle exec rails db:migrate
bundle exec rspec spec/models/quiz_session_spec.rb spec/jobs/close_quiz_answers_job_spec.rb spec/requests/operator_quiz_control_spec.rb spec/requests/participant_quiz_answers_spec.rb spec/requests/participant_quiz_state_spec.rb
bundle exec rubocop app/models/quiz_session.rb app/controllers/operator_quiz_controller.rb app/controllers/participant_quiz_controller.rb app/jobs/close_quiz_answers_job.rb spec/models/quiz_session_spec.rb spec/jobs/close_quiz_answers_job_spec.rb spec/requests/operator_quiz_control_spec.rb spec/requests/participant_quiz_answers_spec.rb spec/requests/participant_quiz_state_spec.rb
```

結果: **60 examples, 0 failures**、RuboCop **9 files, no offenses**、`git diff --check` 成功。
