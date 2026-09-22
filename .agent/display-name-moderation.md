# Display name moderation (TypeSafe Jev via OpenRouter)

参加者の `display_name` を TypeSafe の評価モデル Jev で事前審査し、不適切な名前を登録・改名の段階で拒否する。Jev の呼び出しは OpenRouter Decisions API (`POST https://openrouter.ai/api/alpha/decisions`) 経由。

## 構成

| ファイル | 役割 |
| --- | --- |
| `app/services/display_name_moderation.rb` | Jev `noul` 質問で不審度 0..1 を取得し、閾値以上なら拒否 |
| `app/services/display_name_moderation_config.rb` | 環境変数の読み取り（鍵は ENV のみ・ログ/レスポンス非出力） |
| `app/services/display_name_moderation_transport.rb` | HTTPS POST の小さな境界（注入可能・specでは double に差替） |
| `app/models/participant.rb` | `display_name` 変更時のみ `DisplayNameModeration#inappropriate?` を呼ぶ validate |

## 判定内容（`DisplayNameModeration::INSTRUCTIONS`）

卑猥・下品、差別・ヘイトスピーチ・誹謗中傷、暴力・犯罪・反社会的、運営・主催者・スタッフ・他者・有名人へのなりすまし、個人情報・SNS誘導・宣伝、および○・＊・当て字・ローマ字等による回避表現を不適切とする。指示文は具体例を含む descriptive 形式に調整済み（抽象ルールのみの初期版は不適切名ですら 0.48–0.67 に圧縮され閾値を下回っていたが、現版では不適切 ≥0.74 / 正常 ≤0.11 に分離）。

## 環境変数

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `OPENROUTER_API_KEY` | なし（必須） | OpenRouter の Bearer キー（`sk-or-...`）。未設定なら審査自体をスキップ（ローカル開発は無効） |
| `OPENROUTER_API_URL` | `https://openrouter.ai/api/alpha/decisions` | 評価エンドポイント（HTTPS のみ許可） |
| `OPENROUTER_MODEL` | `~typesafe/jev-latest` | モデル指定（`typesafe/jev-1.13` 等に固定も可） |
| `DISPLAY_NAME_MODERATION_THRESHOLD` | `0.7` | この確率以上で拒否（0..1） |
| `DISPLAY_NAME_MODERATION_FAIL_CLOSED` | 空=fail-open | `true` で API 障害時も拒否。既定はフェイルオープン＋警告ログ |

## 振る舞い

- 対象は `Participant` の `display_name` が変わる save（`POST /api/participants` 登録と `PATCH /api/participants/me` 改名の両方をカバー）
- 拒否時は `errors.add(:display_name, :inappropriate)` → `rescue_from RecordInvalid` が 422 `{ error: "表示名 は使用できない可能性があります。別の表示名を入力してください" }` を返し、frontend の `submitErrorMessage` にそのまま表示される
- 送信するのは表示名と審査ルーブリックのみ。他の参加者情報・セッション情報は送らない
- 応答は 70〜500ms 程度。transport の timeout は open/read/write 各3秒
- `noul` は確率のみ返し理由テキストは返らない。カテゴリ別の理由が必要になったら `choice` 質問への差替で対応できる

注意: OpenRouter 側のキーは TypeSafe 直 API のキーとは別物。TypeSafe の `apikey_...` キーを OpenRouter に送ると 401 になるため、OpenRouter ダッシュボードで発行したキーが必要。

## 実測メモ（2026-09-22, OpenRouter `typesafe/jev-1.13-20260917`、現行プロンプト）

- 不適切例: `主催者_公式アカウント` 0.97, `運営です` 0.97, `admin` 0.87, `死ね` 0.94, `殺すぞ` 0.97, `ちんこ` 0.98, `nigger` 0.99, `ま◯こ` 0.95, `オナニー` 0.98, `090-1234-5678` 0.97, `http://...` 0.98, `LINEID教えて` 0.81, `ヒトラー` 0.81
- 通過例: `たろう` 0.03, `田中太郎` 0.04, `Quiz Player` 0.03, `匿名希望` 0.05, `大谷翔平` 0.07, `穴吹大好き` 0.06
- 既知の限界: `チ○コ` 0.62（伏せ字の取りこぼし）、`シネ`/`kanri`（ひらがな・ローマ字化した和製スラング系）が閾値未満で通過。`幹事` 0.62, `司会` 0.57, `LINE交換` 0.52, `安倍晋三` 0.18 は許可側（イベント用途では概ね妥当）
- 閾値 0.7 は「誤拒否を減らす」側に倒した設定。強めにしたい場合は `DISPLAY_NAME_MODERATION_THRESHOLD=0.6` で SNS誘導や `死にたい`(0.59) 系も拾える

## 検証

```bash
bundle exec rspec spec/services/display_name_moderation_spec.rb spec/requests/participant_registration_spec.rb
bundle exec rubocop app/services/display_name_moderation*.rb app/models/participant.rb spec/services/display_name_moderation_spec.rb
```
