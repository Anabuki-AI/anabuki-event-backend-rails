class ParticipantsController < ApplicationController
  def create
    require_participant_same_origin!
    reject_existing_participant_session!

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

  def update
    require_participant_same_origin!

    session = participant_auth.current_session!
    session.participant.update!(display_name: params[:displayName].to_s.strip)
    render json: participant_json(session.participant, session.expires_at)
  end

  def presence
    require_participant_same_origin!

    observed_at = Time.current
    session = participant_auth.current_session!
    session.update!(waiting_heartbeat_at: observed_at)

    response.headers["Cache-Control"] = "no-store"
    render json: {
      activeParticipantCount: ParticipantSession.active_participant_count(observed_at:),
      totalParticipantCount: Participant.count,
      observedAt: observed_at.utc.iso8601,
      activeWindowSeconds: ParticipantSession::WAITING_ACTIVE_WINDOW_SECONDS
    }
  end

  def reactions
    require_participant_same_origin!

    session = participant_auth.current_session!
    event = ReactionEventStore.record(session_id: session.id, reaction: params.require(:reaction))

    return render_error("Reaction rate limit exceeded", :too_many_requests) unless event

    head :created
  rescue ReactionEventStore::InvalidReaction
    render_error("Reaction is not included in the list", :unprocessable_content)
  rescue ActionController::ParameterMissing
    render_error("reaction is required", :bad_request)
  rescue ActionDispatch::Http::Parameters::ParseError
    render_error("Malformed JSON", :bad_request)
  end

  def destroy_session
    require_participant_same_origin!
    participant_auth.logout!
    head :no_content
  end

  private

  def reject_existing_participant_session!
    return unless participant_auth.current_session

    raise ParticipantAuthError.new("Participant session already exists", :conflict)
  end

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
