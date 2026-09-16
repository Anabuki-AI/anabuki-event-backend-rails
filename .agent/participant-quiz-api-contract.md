# 参加者・運営クイズ API 設計 / 契約

## 設計

`quiz_events` は開始時点の1回の大会、`quiz_event_questions` は問題バンクの編集・削除から独立した問題スナップショット、`quiz_answers` は参加者ごとの一度だけの回答です。イベントstatusの実装・DB/APIにおける正規の終了値は **`FINISHED`**（`COMPLETED` 等ではない）であり、`ACTIVE` → `FINISHED` と遷移します。問題は `PENDING` → `PUBLISHED` → `CLOSED` → `REVEALED` で遷移します。

開始時に `Question` を `position` 順にコピーし、`ConfidenceMultiplier` の `high` / `normal` / `low` を `quiz_events.confidence_multipliers` へ文字列小数（例: `"2.00"`）で保存します。回答時にはイベントのスナップショット倍率を `quiz_answers.multiplier_snapshot` に再保存し、正解時だけ `base_points` (現在は100) × 倍率を `score` に保存します。問題バンクや倍率をイベント開始後に更新しても進行中イベントには反映されません。

開始・運営状態遷移はトランザクションと PostgreSQL advisory lock、回答と reveal の競合は `quiz_event_questions` の行lockで直列化します。DBの参加者・イベント問題一意indexも回答の重複を防ぎます。`CLOSED` の問題は reveal 前に次の問題を publish できません。

## 認証・保護

- 運営 API は既存の `OperatorAuth` の `MANAGER` session が必須です。`APPLICANT` は `403 {"error":"Manager access is required"}`。
- 参加者 API は既存の `participant_session` Cookie が必須です。
- すべての POST は既存の同一Origin規約に従います。参加者は `PUBLIC_BASE_URL`、運営は `PUBLIC_BASE_URL` または `OPERATOR_FRONTEND_URL`。`Origin` がない非ブラウザ呼び出しは既存どおり許可します。
- `GET /api/participant/quiz/state` は必ず `Cache-Control: no-store` を返します。フロントは5秒ポーリングしてください。

## 運営 API

| Method | Path | 成功 | 内容 |
| --- | --- | --- | --- |
| GET | `/api/operator/quiz/state` | 200 | 最新イベントと全問題スナップショット |
| POST | `/api/operator/quiz/start` | 201 | ACTIVEイベントを開始し、問題・倍率をsnapshot |
| POST | `/api/operator/quiz/publish` | 200 | 次のPENDING問題をPUBLISHEDへ |
| POST | `/api/operator/quiz/close` | 200 | PUBLISHED問題をCLOSEDへ（回答受付終了） |
| POST | `/api/operator/quiz/reveal` | 200 | PUBLISHEDまたはCLOSED問題をREVEALEDへ。最後ならイベントをFINISHEDへ |

運営state例です。運営レスポンスは正答を含みます。

```json
{
  "event": {
    "id": 12,
    "status": "ACTIVE",
    "startedAt": "2026-09-30T01:00:00Z",
    "finishedAt": null,
    "confidenceMultipliers": { "high": "2.00", "normal": "1.00", "low": "0.50" }
  },
  "questions": [{
    "id": 31,
    "sourceQuestionId": 7,
    "position": 1,
    "status": "PUBLISHED",
    "questionText": "問題文",
    "choiceA": "選択肢A",
    "choiceB": "選択肢B",
    "choiceC": "選択肢C",
    "choiceD": "選択肢D",
    "correctAnswer": "A",
    "imageUrl": null,
    "basePoints": 100
  }]
}
```

イベントが一件もなければ `{"event":null,"questions":[]}`。不正な遷移（ACTIVEイベントが無い、公開済み問題がある、回答締切済み問題がある、次の問題が無い等）は `409`、開始時の問題ゼロだけは `422` です。

## 参加者 API

| Method | Path | 成功 | Body |
| --- | --- | --- | --- |
| GET | `/api/participant/quiz/state` | 200 | 下記state |
| POST | `/api/participant/quiz/answers` | 201（新規）/ 200（同一内容の競合再送） | `{ "quizEventQuestionId": 31, "answer": "A", "confidenceLevel": "high" }` |

イベント開始前のstateは `{"event":null,"question":null}`。公開中のstate例は次です。

```json
{
  "event": {
    "id": 12,
    "status": "ACTIVE",
    "startedAt": "2026-09-30T01:00:00Z",
    "finishedAt": null,
    "totalQuestions": 10,
    "revealedQuestionCount": 2,
    "confidenceMultipliers": { "high": "2.00", "normal": "1.00", "low": "0.50" },
    "totalScore": "300.00"
  },
  "question": {
    "id": 33,
    "position": 3,
    "status": "PUBLISHED",
    "questionText": "問題文",
    "choiceA": "選択肢A",
    "choiceB": "選択肢B",
    "choiceC": "選択肢C",
    "choiceD": "選択肢D",
    "imageUrl": null,
    "myAnswer": {
      "id": 91,
      "quizEventQuestionId": 33,
      "answer": "A",
      "confidenceLevel": "high",
      "submittedAt": "2026-09-30T01:01:00Z"
    }
  }
}
```

`PUBLISHED` / `CLOSED` の参加者レスポンスには **`correctAnswer`、`isCorrect`、`points` を一切含めません**。またイベントでまだ1問もREVEALEDでない間は `totalScore` キー自体を含めません。`REVEALED` になった問題だけ、`question.correctAnswer` と `myAnswer.isCorrect` / `myAnswer.points` を返し、イベントには公開済み問題だけを合計した `totalScore` を返します。回答POSTも reveal 前の成功レスポンスでは選択肢・自信度・提出時刻だけを返し、正誤・点数を返しません。

回答はPUBLISHEDの問題だけで、同じ参加者・イベント問題には一度だけです。締切後・公開前は `409`、すでに確定済みの回答への通常の再送は `409` です。ただし同時リクエストがDB一意indexで競合した場合は、既存回答と `answer`・`confidenceLevel` が同一なら既存回答を `200` で返し、どちらかが異なれば `409` を返します。`answer` が A〜D 以外または `confidenceLevel` が high/normal/low 以外は、英語のモデルvalidationではなく契約どおりのメッセージで `422` です。
