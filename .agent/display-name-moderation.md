# Display name moderation (TypeSafe Jev)

参加者の `display_name` を TypeSafe の評価モデル Jev で事前審査し、不適切な名前を登録・改名の段階で拒否する。

## 構成

| ファイル | 役割 |
| --- | --- |
| `app/services/display_name_moderation.rb` | Jev `noul` 質問で不審度 0..1 を取得し、閾値以上なら拒否 |
| `app/services/display_name_moderation_config.rb` | 環境変数の読み取り（鍵は ENV のみ・ログ/レスポンス非出力） |
| `app/services/display_name_moderation_transport.rb` | HTTPS POST の小さな境界（注入可能・specでは double に差替） |
| `app/models/participant.rb` | `display_name` 変更時のみ `DisplayNameModeration#inappropriate?` を呼ぶ validate |

## 判定内容（`DisplayNameModeration::INSTRUCTIONS`）

卑猥・下品、差別・ヘイト・誹謗中傷、暴力・犯罪・反社会的、運営・他者・有名人へのなりすまし、個人情報（電話番号・メール・住所・他人の本名）、宣伝・URL・スパム、および記号・文字置き換えによる回避表現を不適切とする。

## 環境変数

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `TYPESAFE_API_KEY` | なし（必須） | TypeSafe API の Bearer キー。未設定なら審査自体をスキップ（ローカル開発は無効） |
| `TYPESAFE_API_URL` | `https://api.typesafe.ai/v1/systemone` | 評価エンドポイント（HTTPS のみ許可） |
| `TYPESAFE_MODEL` | `jev-latest` | モデル指定（`jev-1.13.0` 等に固定も可） |
| `DISPLAY_NAME_MODERATION_THRESHOLD` | `0.7` | この確率以上で拒否（0..1） |
| `DISPLAY_NAME_MODERATION_FAIL_CLOSED` | 空=fail-open | `true` で API 障害時も拒否。既定はフェイルオープン＋警告ログ |

## 振る舞い

- 対象は `Participant` の `display_name` が変わる save（`POST /api/participants` 登録と `PATCH /api/participants/me` 改名の両方をカバー）
- 拒否時は `errors.add(:display_name, :inappropriate)` → `rescue_from RecordInvalid` が 422 `{ error: "表示名 は使用できない可能性があります。別の表示名を入力してください" }` を返し、frontend の `submitErrorMessage` にそのまま表示される
- 送信するのは表示名と審査ルーブリックのみ。他の参加者情報・セッション情報は送らない
- 応答は 70〜500ms 程度。transport の timeout は open/read/write 各3秒
- `noul` は確率のみ返し理由テキストは返らない。カテゴリ別の理由が必要になったら `choice` 質問への差替で対応できる

## 実測メモ（2026-09-22, `jev-1.13.0`）

- `主催者_公式アカウント` → 0.86（なりすまし検出）
- `たろう` → 0.03（通常名）

## 検証

```bash
bundle exec rspec spec/services/display_name_moderation_spec.rb spec/requests/participant_registration_spec.rb
bundle exec rubocop app/services/display_name_moderation*.rb app/models/participant.rb spec/services/display_name_moderation_spec.rb
```
