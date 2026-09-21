# In-memory projector reactions

`ReactionEventStore` keeps only `id`, `reaction`, and `at` in the Rails process. It is mutex-protected, retains at most 100 events for 30 seconds, and keeps the existing 500 ms per-session throttling in the same bounded memory store.

`POST /api/participants/reactions` authenticates the existing participant cookie before recording an event. `GET /api/operator/quiz/reactions` retains the existing `{ reactions, cursor }` polling contract and serializes event time as `reacted_at` for the existing projector client.

The new migration drops the old `participant_reactions` table and `participant_sessions.last_reaction_at`; the historic migrations are retained because they are already on main. Tournament reset no longer reports or deletes persisted reactions and clears the ephemeral store only after a successful reset transaction.
