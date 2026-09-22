# Operator console participant roster: lists every registered participant for
# the management screen and removes individual entries (test rows, duplicates,
# inappropriate registrations). Deleting cascades to that participant's
# sessions, answers, confidence selections and reactions through the database
# foreign keys.
class OperatorParticipantsController < ApplicationController
  before_action :authorize_event_operator!

  def index
    answered_counts = ParticipantAnswer.group(:participant_id).count
    render json: Participant.order(created_at: :desc).map { |participant| participant_json(participant, answered_counts) }
  end

  def destroy
    participant = Participant.find(params[:id])
    display_name = participant.display_name
    participant.destroy!

    AuditLogRecorder.record(
      type: "PARTICIPANT_DELETED",
      identity: audit_actor_identity,
      target_type: "PARTICIPANT",
      target_id: participant.id,
      detail: { "displayName" => display_name }
    )
    head :no_content
  end

  private

  def participant_json(participant, answered_counts)
    {
      id: participant.id,
      displayName: participant.display_name,
      gender: participant.gender,
      ageGroup: participant.age_group,
      studentType: participant.student_type,
      school: participant.school,
      department: participant.department,
      answeredCount: answered_counts.fetch(participant.id, 0),
      registeredAt: participant.created_at.iso8601
    }
  end
end
