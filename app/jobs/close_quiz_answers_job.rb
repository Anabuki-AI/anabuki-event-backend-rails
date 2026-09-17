# Finalizes an operator-requested answer close after its visible countdown.
# The question ID and phase start timestamp make a delayed job harmless after
# a reset, a new question, or a newer close request.
class CloseQuizAnswersJob < ApplicationJob
  queue_as :default

  def perform(question_id, closing_started_at)
    QuizSession.current.complete_requested_close!(
      question_id:,
      closing_started_at: Time.iso8601(closing_started_at)
    )
  rescue ArgumentError
    # A malformed/stale serialized argument must never close the current quiz.
    nil
  end
end
