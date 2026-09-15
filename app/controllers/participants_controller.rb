class ParticipantsController < ApplicationController
  def create
    require_participant_same_origin!

    participant = Participant.new(participant_params)
    raw_token = nil
    session = nil

    Participant.transaction do
      participant.save!
      raw_token, session = participant_auth.create_session!(participant)
    end

    participant_auth.write_session_cookie!(raw_token)
    render json: participant_json(participant, session.expires_at), status: :created
  end

  def me
    session = participant_auth.current_session!
    render json: participant_json(session.participant, session.expires_at)
  end

  def destroy_session
    require_participant_same_origin!
    participant_auth.logout!
    head :no_content
  end

  private

  def participant_params
    {
      display_name: params[:displayName],
      gender: params[:gender],
      age_group: params[:ageGroup],
      student_type: params[:studentType],
      school: params[:school],
      department: params[:department],
      agreed_terms: params[:agreedTerms]
    }
  end

  def participant_json(participant, expires_at)
    {
      id: participant.id,
      displayName: participant.display_name,
      gender: participant.gender,
      ageGroup: participant.age_group,
      studentType: participant.student_type,
      school: participant.school,
      department: participant.department,
      agreedTerms: participant.agreed_terms,
      sessionExpiresAt: expires_at.iso8601
    }
  end
end
