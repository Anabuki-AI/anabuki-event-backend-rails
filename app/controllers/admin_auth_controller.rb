class AdminAuthController < ApplicationController
  def session
    render json: session_json(admin_auth.any_session!)
  end

  def logout
    require_same_origin!
    session = begin
      admin_auth.any_session!
    rescue AdminAuthError
      nil
    end
    admin_auth.logout!
    if session && !session.applicant?
      AuditLogRecorder.record(type: "ADMIN_LOGGED_OUT", identity: session.identity)
    end
    head :no_content
  end

  def exchange
    require_same_origin!
    admin_auth.exchange_applicant_session!
    head :no_content
  end

  private

  def session_json(session)
    {
      email: session.identity.email,
      googleSub: session.identity.google_sub,
      accessSource: session.source,
      permissions: session.permissions,
      expiresAt: session.record.expires_at.iso8601
    }
  end
end
