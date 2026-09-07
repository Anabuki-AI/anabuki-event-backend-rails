class AdminAuthController < ApplicationController
  def session
    render json: session_json(admin_auth.any_session!)
  end

  def logout
    require_same_origin!
    admin_auth.logout!
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
