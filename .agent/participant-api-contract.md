# 参加者登録 API 契約（PR #17）

このAPIは参加者用の独立した UUID + Cookie セッションです。`AdminAuth` / `OperatorAuth`、Google identity、メールアドレス、パスワードを参加者認証へ流用しません。セッション cookie の生トークンは `participant_session` だけに置き、DBの `participant_sessions.token_hash` には SHA-256 hash だけを保存します。

## API

状態を変えるリクエストは `Origin` が `PUBLIC_BASE_URL` と同一 origin の場合だけ受け付けます（非ブラウザクライアントは `Origin` なしで利用可能です）。Cookieは `HttpOnly; SameSite=Lax; Path=/` で、`PUBLIC_BASE_URL` が HTTPS の場合は `Secure` も付与します。

| Method | Path | 説明 |
| --- | --- | --- |
| `POST` | `/api/participants` | UUID参加者を作成し、セッションcookieを発行する |
| `GET` | `/api/participants/me` | cookieから現在の参加者を返す |
| `DELETE` | `/api/participants/session` | 現cookieに対応するセッションをrevokeし、cookieを削除する |

`POST /api/participants` のJSON body:

```json
{
  "displayName": "Quiz Player",
  "gender": "no_answer",
  "ageGroup": "20s",
  "studentType": "not_student",
  "school": "",
  "department": "",
  "agreedTerms": true
}
```

成功時（`201 Created`）および `GET /api/participants/me`（`200 OK`）は、以下を返します。`id` は pgcrypto `gen_random_uuid()` で発行する UUID文字列です。`displayName` は表示用であり、一意ではなく、認証識別子ではありません。

```json
{
  "id": "e4d909c2-8f69-46f5-b7e9-7f5e6f1d8e80",
  "displayName": "Quiz Player",
  "gender": "no_answer",
  "ageGroup": "20s",
  "studentType": "not_student",
  "school": "",
  "department": "",
  "agreedTerms": true,
  "sessionExpiresAt": "2026-10-16T00:00:00Z"
}
```

`GET /api/participants/me` に有効なcookieが無い、失効済み、またはrevoke済みの場合は `401 {"error":"Participant session is required"}` を返します。`DELETE` は未ログインでも `204 No Content` です。

## Frontend PR #10 との非互換点

Frontend PR #10（`feature/user-registration`）は次の旧契約を呼びますが、本APIは**互換endpointを提供しません**。

- `POST /api/users` に `userName` を送り、数値 `id` と `userName` を期待する。
- `GET /api/usernames/available` で表示名の一意性を確認する。
- APIエラー時に登録成功を模倣するモックへfallbackする。

新契約は `/api/participants`、UUID `id`、非一意の `displayName`、Cookieで解決する `/api/participants/me` です。PR #10 はメールアドレスやパスワードを送らない一方、上記のpath・field名・応答型・username availability・モックfallbackが新要件と矛盾します。フロントエンドを変更しない今回の作業ではそのPRを変更していません。接続時にはこのAPI契約へ置換し、ブラウザがAPIをcross-originで直接呼ぶ構成ならcookieを送受信するため `credentials: "include"` も設定してください。
