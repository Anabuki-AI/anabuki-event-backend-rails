# 問題ごとの配点（points）フィールド追加

ブランチ: `feat/question-points`（worktree: `anabuki-event/.worktree/feat-question-points-backend`）
関連: フロントエンド側は `anabuki-event-frontend` の `feat/question-points` ブランチで対応（問題追加・編集フォームに配点入力欄を追加）。

## 背景・目的

イベント開催者向け「問題管理」画面（`event_operator/management.vue` → 問題追加・編集モーダル）に、問題ごとの得点（配点）を入力・編集できるようにする依頼。
調査の結果、追加前の `Question` モデルには得点フィールドは存在しなかった。

## 調査で分かった既存の採点ロジック（重要・未変更）

- `ParticipantAnswer::BASE_SCORE = 100`（`app/models/participant_answer.rb`）が全問題共通の固定基礎点として使われている。
- 実際の獲得点数は `ParticipantAnswer.record!` 内で `BASE_SCORE * confidence_multiplier`（自信度倍率。`ConfidenceMultiplier` テーブルで `high/normal/low` ごとに運営者が設定可能、既定 2.00/1.00/0.50）として回答時にスナップショットされる。
- つまり「配点」は現状、問題ごとではなく **全問題共通の定数** で管理されている。

## 今回のスコープと意図的に対応しなかったこと

今回のタスク範囲は「問題の追加・編集画面に得点フィールドを追加する」こと（モデル・API・フォーム）。
そのため実装したのは:

- `questions.points`（integer, NOT NULL, デフォルト 100）カラムの追加
- `Question` モデルでのバリデーション（1〜1000の整数、既定100）
- 問題作成・更新APIでの `points` パラメータの受け取り・返却

**意図的にやらなかったこと**: `ParticipantAnswer.record!` の採点式を `BASE_SCORE`固定から `question.points` を使う形に変更すること。
理由:

- 採点式を変えると、既に画面上ダミー表示されているプレビュー（フロントの `QuestionPreviewModal.vue` の固定 `CONFIDENCE_POINTS`）や、ランキング計算（`rankings_controller.rb` が `awarded_points` の合計で順位付け）に直接影響する、ゲームルールそのものの変更になる。
- 大会本番（9月末開催、今日は2026-09-17）が目前で、採点式の変更はイベントの公平性・結果に関わる重大な意思決定であり、今回のチケット記述（モデル・API・フォームの追加）には明示的に含まれていなかったため、独断で変更しなかった。
- 現状、`points` カラムは問題データとして保存・編集できるが、**実際の採点計算にはまだ使われていない**（`BASE_SCORE = 100` のまま）。

**フォローアップとして必要な意思決定**: 「配点」を実際の得点計算に反映させる（`BASE_SCORE` を `question.points` に置き換える）かどうかは、ユーザー（運営チーム）に確認の上で別タスクとして対応することを推奨する。反映する場合は `ParticipantAnswer.record!` の変更に加え、フロントの `QuestionPreviewModal.vue` のプレビュー表示、`users/answer.vue` 側の表示なども合わせて見直す必要がある。

## 変更内容

- `db/migrate/20260918040000_add_points_to_questions.rb`
  - `questions.points` (integer, NOT NULL, default: 100) を追加
  - チェック制約 `questions_points_positive`（`points > 0`）を追加（`position` カラムの既存パターンに合わせた最低限のDB制約。上限はRailsバリデーション側で担保）
- `app/models/question.rb`
  - `MIN_POINTS = 1` / `MAX_POINTS = 1000` を追加
  - `validates :points, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: MIN_POINTS, less_than_or_equal_to: MAX_POINTS }`
- `app/controllers/admin_questions_controller.rb`
  - `QUESTION_ERROR_KEYS` に `points: "points"` を追加
  - `question_attributes` で `points` パラメータ（省略可・省略時はDBデフォルト100が適用される）を受け取り
  - `points_provided?` / `points_parameter_valid?` を追加し、`question_parameter_type_errors` で型チェック（Integer または数字のみの文字列のみ許可。オブジェクト・配列・真偽値・小数文字列などは `"points" => "must be a whole number"` エラーで弾く。multipart送信では数値も文字列で届くため、その両対応が必要）
  - `question_json` のレスポンスに `points` を追加
- `spec/models/question_spec.rb`：デフォルト値・範囲バリデーションのテスト追加
- `spec/requests/admin_question_management_spec.rb`：作成・更新・範囲外・型不正（文字列/オブジェクト）・multipart送信のテストを追加

## API契約（差分）

`POST/PUT /api/admin/questions` のリクエストで `points`（省略可、整数 1〜1000、省略時100）を送信できる。
レスポンス（`question_json`）に `points`（integer）が追加される。

例:
```json
{
  "id": 1,
  "position": 1,
  "questionText": "...",
  "points": 100,
  ...
}
```

バリデーションエラー時のフィールドキーは `points`（camelCaseそのまま、変換不要な単語のため）。

## テスト

`bundle exec rspec` で全182件成功（既存分含む）。`bundle exec rubocop` も対象ファイルで検査済み・指摘なし。

ローカルでのテスト実行コマンド（このリポジトリの `.mise.toml` の `backend:test` タスクを参考に、postgresコンテナがホストの5433番ポートで稼働している前提）:

```bash
RAILS_ENV=test POSTGRES_PORT=5433 \
  DATABASE_URL="postgresql://anabuki:anabuki@localhost:5433/anabuki_event_rails_test" \
  OPERATOR_DATABASE_URL="postgresql://anabuki:anabuki@localhost:5433/anabuki_event_operator_test" \
  bundle exec rails db:prepare
# 同じ環境変数で
bundle exec rspec
```
