class OperatorVotingRateController < ApplicationController
  before_action :authorize_event_operator!

  def index
    total_participants = Participant.count
    answered_counts = ParticipantAnswer.group(:question_id).count

    render json: {
      questions: Question.order(:position).map { |question|
        answered_count = answered_counts.fetch(question.id, 0)
        {
          question_id: question.id,
          position: question.position,
          answered_count: answered_count,
          answered_rate: answered_rate(answered_count, total_participants)
        }
      },
      total_participants:
    }
  end

  private

  def answered_rate(answered_count, total_participants)
    return 0.0 if total_participants.zero?

    (answered_count.to_f / total_participants).round(2)
  end
end
