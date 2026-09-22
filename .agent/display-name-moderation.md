# Display name moderation (TypeSafe Jev via OpenRouter)

参加者の `display_name` を TypeSafe の評価モデル Jev で事前審査し、不適切な名前を登録・改名の段階で拒否する。Jev の呼び出しは OpenRouter Decisions API (`POST https://openrouter.ai/api/alpha/decisions`) 経由。

## 構成

| ファイル | 役割 |
| --- | --- |
| `app/services/display_name_moderation.rb` | Jev `noul` 質問を日英2言語で1リクエストに送り、高い方の不審度 0..1 が閾値以上なら拒否 |
| `app/services/display_name_moderation_config.rb` | 環境変数の読み取り（鍵は ENV のみ・ログ/レスポンス非出力） |
| `app/services/display_name_moderation_transport.rb` | HTTPS POST の小さな境界（注入可能・specでは double に差替） |
| `app/models/participant.rb` | `display_name` 変更時のみ `DisplayNameModeration#inappropriate?` を呼ぶ validate |

## 判定内容（`DisplayNameModeration::INSTRUCTIONS`）

卑猥・下品、差別・ヘイトスピーチ・誹謗中傷、暴力・犯罪・反社会的、運営・主催者・スタッフ・他者・有名人へのなりすまし、個人情報・SNS誘導・宣伝、および○・＊・当て字・ローマ字等による回避表現を不適切とする。指示文は descriptive 形式（各カテゴリを説明的に列挙・卑語は直接書かない）に調整済み。抽象ルールのみの初期版は不適切名ですら 0.48–0.67 に圧縮され閾値を下回っていた。また日英どちらかだけでは取りこぼしがあるため（日本語版は伏字卑語に強く、英語版は運営なりすまし・英スラングに強い）、同一リクエスト内で `inappropriate_display_name_ja` / `_en` の2問を投げ、高い方の確率を採用する。コスト・レイテンシは1リクエスト分のまま。

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

max(ja, en) 採用値:
- 不適切例: `主催者_公式アカウント` 0.97, `運営です` 0.97, `admin` 0.95, `死ね` 0.95, `ちんこ` 0.98, `nigger` 0.99, `ま◯こ` 0.94, `まん○` 0.75(ja), `幹事` 0.80(en), `幹事長` 0.87(en), `司会` 0.78(en), `LINE交換` 0.74(en), `090-1234-5678` 0.97, `http://...` 0.98, `ヒトラー` 0.93, `オナニー` 0.98
- 通過例: `たろう` 0.03, `田中太郎` 0.04, `Quiz Player` 0.03, `匿名希望` 0.05, `大谷翔平` 0.34(en側で上昇するも閾値以下), `彼女募集中` 0.24, `穴吹大好き` 0.11, `kanri` 0.62, `死にたい` 0.63
- 既知の限界: `チ○コ` 0.63（伏せ字の取りこぼし）、`シネ` 0.07（ひらがな化で大幅減衰）。閾値を下げるなら `DISPLAY_NAME_MODERATION_THRESHOLD=0.6` で SNS誘導系・`死にたい`系・`kanri`も拾えるが `幹事`クラスの日常語との誤判定リスクが増えるため既定 0.7 を推奨

## 検証

```bash
bundle exec rspec spec/services/display_name_moderation_spec.rb spec/requests/participant_registration_spec.rb
bundle exec rubocop app/services/display_name_moderation*.rb app/models/participant.rb spec/services/display_name_moderation_spec.rb
```
