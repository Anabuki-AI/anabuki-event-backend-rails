# 通常問題から中継問題へ編集したときの正解リセット

- ブランチ: `fix/relay-answer-reset-on-edit`
- 対象: `Question`
- 既存の通常問題を中継問題へ変更する更新では、旧 `correct_answer` をDB必須値のプレースホルダ `A` に正規化する。
- 未選択中継問題の正解変更ロックは維持し、通常問題からの切替だけは正規化処理を許可する。
- 回帰テスト: `spec/models/question_spec.rb`, `spec/requests/admin_question_management_spec.rb`

## 検証

- `mise exec -- bundle exec rspec spec/models/question_spec.rb spec/requests/admin_question_management_spec.rb`
- `mise exec -- bundle exec rubocop app/models/question.rb spec/models/question_spec.rb spec/requests/admin_question_management_spec.rb`
