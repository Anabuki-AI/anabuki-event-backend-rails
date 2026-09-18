class RankingsController < ApplicationController
  RANKING_SIZE = 20

  before_action :authorize_ranking_viewer!

  def index
    entries = ranked_entries

    render json: {
      rankings: entries.first(RANKING_SIZE),
      me: entries.find { |entry| entry[:participant_id] == current_participant&.id }
    }
  end

  private

  # Shared screen: participants watch their own standing, operators watch the
  # event. Either session grants read access.
  def authorize_ranking_viewer!
    participant_auth.current_session!
  rescue ParticipantAuthError
    authorize_event_operator!
  end

  def current_participant
    return @current_participant if defined?(@current_participant)

    @current_participant = begin
      participant_auth.current_session!.participant
    rescue ParticipantAuthError
      nil
    end
  end

  # Competition ranking: equal scores share the same rank and the next rank
  # skips (1, 2, 2, 4...). Participants without answers are unranked.
  def ranked_entries
    quiz_session = QuizSession.current
    answers = ParticipantAnswer
      .joins(:participant, :question)
      .where.not(questions: { revealed_at: nil })

    if quiz_session.status == "in_progress" && quiz_session.current_question_id.present?
      answers = answers.where.not(participant_answers: { question_id: quiz_session.current_question_id })
    end

    rows = answers
      .group("participants.id", "participants.display_name")
      .order(Arel.sql("SUM(participant_answers.awarded_points) DESC"), "participants.id")
      .pluck("participants.id", "participants.display_name", "SUM(participant_answers.awarded_points) AS total_points")

    previous_points = nil
    previous_rank = 0
    rows.each_with_index.map do |(participant_id, display_name, total_points), index|
      rank = total_points == previous_points ? previous_rank : index + 1
      previous_points = total_points
      previous_rank = rank

      {
        rank:,
        participant_id:,
        display_name:,
        total_points:
      }
    end
  end
end
