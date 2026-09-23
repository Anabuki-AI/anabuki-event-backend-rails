class OperatorAuthController < ApplicationController
  def session
    operator = operator_auth.any_session!
    render json: session_json(operator)
  end

  def logout
    require_same_origin!(config: operator_auth_config)
    session = begin
      operator_auth.any_session!
    rescue OperatorAuthError
      nil
    end
    operator_auth.logout!
    if session && !session.applicant?
      AuditLogRecorder.record(type: "OPERATOR_LOGGED_OUT", identity: session.identity)
    end
    head :no_content
  end


  private

  def session_json(session)
    {
      email: session.identity.email,
      googleSub: session.identity.google_sub,
      accessSource: session.source,
      expiresAt: session.record.expires_at.iso8601
    }
  end
end
