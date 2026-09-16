# 参加者登録 API 契約（PR #17）

このAPIは参加者用の独立したUUID + Cookieセッションです。管理者・運営者の認証とは共有せず、セッションcookieの生トークンは `participant_session` だけに置き、DBの `participant_sessions.token_hash` には SHA-256 hashだけを保存します。

## API

状態を変えるリクエストは `Origin` が `PUBLIC_BASE_URL` と同一 origin の場合だけ受け付けます（非ブラウザクライアントは `Origin` なしで利用可能です）。Cookieは `HttpOnly; SameSite=Lax; Path=/` で、`PUBLIC_BASE_URL` が HTTPS の場合は `Secure` も付与します。

| Method | Path | 説明 |
| --- | --- | --- |
| `POST` | `/api/participants` | UUID参加者を作成し、セッションcookieを発行する |
| `GET` | `/api/participants/me` | cookieから現在の参加者を返す |
| `POST` | `/api/participants/presence` | 現在のセッションの待機heartbeatを記録し、待機中の参加者数だけを返す |
| `POST` | `/api/participants/reactions` | 現在のセッションに紐づく待機画面リアクションイベントを記録する |
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

成功時（`201 Created`）および `GET /api/participants/me`（`200 OK`）は、以下を返します。`id` は pgcrypto `gen_random_uuid()` で発行する UUID文字列です。`displayName` は表示用であり、一意ではありません。

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

## 待機人数 presence

`POST /api/participants/presence` は有効な参加者cookieを必要とし、現在の `participant_sessions.waiting_heartbeat_at` をサーバー時刻で更新します。revoke済み・失効済みを除き、観測時刻から75秒以内にheartbeatを送ったセッションを `participant_id` ごとに重複排除して数えます。レスポンスは個人情報・参加者ID・セッション情報を含まず、常に `Cache-Control: no-store` です。`observedAt` は UTC の ISO 8601 表記（末尾 `Z`）で返します。

```json
{
  "activeParticipantCount": 42,
  "observedAt": "2026-09-30T12:00:00Z",
  "activeWindowSeconds": 75
}
```

無効・未ログインのcookieは `401 {"error":"Participant session is required"}`、許可されない `Origin` は `403 {"error":"Origin is not allowed"}` を返します。

## 待機画面リアクション

`POST /api/participants/reactions` は有効な参加者cookieを必要とし、現在のcookieから解決した `participant` と `participant_session` にイベントを紐付けます。クライアントが参加者ID・セッションID・時刻を指定することはできません。サーバーが `reaction` と `reacted_at`（サーバー時刻）をイベント履歴として保存し、将来の運営画面で集計・表示に利用します。

JSON body:

```json
{
  "reaction": "👏"
}
```

許可する `reaction` は現在の待機画面で使う `👏`、`🎉`、`🙌`、`😂`、`😢`、`😲`、`👍`、`❤️` だけです。成功時は個人情報・参加者ID・セッション情報を返さず、bodyなしの `201 Created` を返します。

不正なJSONまたは `reaction` の欠落は `400`、許可されないreactionは `422` を返します。無効・未ログインのcookieは `401 {"error":"Participant session is required"}`、許可されない `Origin` は `403 {"error":"Origin is not allowed"}` を返します。
