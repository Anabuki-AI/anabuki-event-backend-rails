# Production tournament reset contract

## Endpoint

`POST /api/operator/quiz/reset`

The endpoint uses the same authorization policy as the other operator quiz controls:

- an `OperatorAuth` manager session, or
- an `AdminAuth` management/environment session with `MANAGEMENT_PAGE_VIEW`.

The authorized session is retained as the audit principal for the request; audit code does not re-resolve cookies. Admin management is preferred when it authorizes successfully. If an admin applicant cookie and an operator manager cookie coexist, the operator manager authorizes the request and is the recorded reset actor.

Browser requests must also use an Origin allowed by the operator or admin frontend configuration. Anonymous/applicant sessions are rejected before reset confirmation is evaluated.

## Required server-side confirmation

JSON request body:

```json
{ "confirmation": "RESET" }
```

The backend compares this value exactly. Missing values, cancellation values such as `CANCEL`, different casing, surrounding whitespace, booleans, and all other values return:

```http
HTTP/1.1 422 Unprocessable Content
Content-Type: application/json

{ "error": "confirmation must exactly equal RESET" }
```

A rejected confirmation performs no participant purge, quiz-state/reveal reset, or audit write.

## Atomic reset behavior

One PostgreSQL transaction:

1. locks the singleton quiz session;
2. takes exclusive locks on participant-owned tables in the canonical live-write order: `participants`, `participant_sessions`, `participant_reactions`, `participant_quiz_confidence_selections`, then `participant_answers`;
3. deletes all `participant_reactions`, `participant_answers`, `participant_quiz_confidence_selections`, `participant_sessions`, and `participants` rows;
4. clears every `questions.revealed_at` value;
5. resets the singleton `quiz_sessions` row to the initial waiting state, with current question, phase/timestamps, and finished elapsed time cleared; and
6. inserts the durable `TOURNAMENT_RESET` audit row.

Registration uses `participants` → `participant_sessions`; reactions explicitly lock their participant before their session and then insert into `participant_reactions`. Keeping reset in the same order prevents reset/registration and reset/reaction lock cycles. Participant writes that begin while reset owns the table locks resume only after commit and belong to the newly reset tournament.

If any step, including the audit insert, fails, every destructive change rolls back.

The reset preserves:

- questions and Active Storage attachments;
- confidence multipliers and other settings;
- admin/operator identities, device sessions, OAuth states, and access records; and
- all prior audit rows.

## Success response

The reset transaction captures the reset quiz state after all destructive updates and the audit insert. That captured snapshot remains at the response top level; the controller does not issue a new live state query after commit. Therefore a registration or quiz start committed immediately after reset cannot make the reset response appear non-waiting or non-empty. `reset_operation` adds the completed operation metadata:

```json
{
  "status": "waiting",
  "phase": null,
  "phase_started_at": null,
  "finished_elapsed_seconds": null,
  "current": null,
  "next_question": null,
  "question_count": 12,
  "total_participants": 0,
  "reset_operation": {
    "operation_id": "4f612df6-289e-41bb-8931-a6da585a2e64",
    "started_at": "2026-09-30T09:00:00.000000Z",
    "completed_at": "2026-09-30T09:00:00.025000Z",
    "affected_rows": {
      "participant_reactions": 45,
      "participant_answers": 300,
      "confidence_selections": 300,
      "participant_sessions": 50,
      "participants": 50,
      "question_reveals": 12,
      "quiz_sessions": 1
    }
  }
}
```

Counts are the rows changed by this operation and contain no participant identifiers or profile values.

## Audit contract

The reset appends one `audit_logs` row in the reset transaction:

- `event_type`: `TOURNAMENT_RESET`
- `operation_id`: unique UUID, also used as `target_id`
- `operation_started_at`, `operation_completed_at`: non-null and ordered
- `occurred_at`: the completion timestamp
- `actor_email`, `actor_google_sub`: required, non-blank snapshot of the exact authorized principal; `admin_identity_id` is populated for an admin actor and null for an operator actor
- `target_type`: `TOURNAMENT`
- `detail`: scalar, non-PII counts only:
  - `participantsDeleted`
  - `participantSessionsDeleted`
  - `participantReactionsDeleted`
  - `participantAnswersDeleted`
  - `confidenceSelectionsDeleted`
  - `questionRevealsReset`
  - `quizSessionsReset`

`GET /api/admin/audit-logs` exposes these operation fields as `operationId`, `operationStartedAt`, and `operationCompletedAt`. The application rejects a reset without an actor identity before opening the destructive transaction. The database enforces the event enum, unique non-null operation IDs, required reset operation metadata, non-blank actor email/Google subject snapshots, and timestamp ordering.
