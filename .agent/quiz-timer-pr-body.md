問題ごとの制限時間とフェーズ開始時刻をAPIに追加し、運営画面で経過時間・カウントダウンを表示できるようにします。次問題は問題文・全選択肢・画像を返し、正解は含めません。

- 問題の `timeLimitSeconds` は省略可能、null / 空文字で解除。正の整数とDB範囲を検証し、先頭ゼロ付き文字列も10進数で扱います。
- start / publish / close / reveal / finish / reset で `phase_started_at` を更新。現在問題の既存表示フィールドと main 済みの配点機能は維持しています。
- 対応frontendが時間切れ時に既存のclose APIを呼びます。サーバー側の期限ジョブは追加していません。
- nullableカラム2件のマイグレーションが必要です。既存問題は制限時間なしを維持します。

検証: RSpec **192件成功**、RuboCop **135ファイル指摘なし**、`git diff --check` 成功。既存main作業ツリーを保護し、最新origin/mainの専用worktreeで検証しました。
